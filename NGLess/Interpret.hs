{- Copyright 2015-2016 NGLess Authors
 - License: MIT
 -}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
module Interpret
    ( interpret
    , _evalIndex
    , _evalUnary
    , _evalBinary
    ) where


import Control.Applicative
import Control.Monad
import Control.Monad.Except
import Control.Monad.Identity
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Trans.Resource

import qualified Data.ByteString.Char8 as B
import qualified Data.Map as Map

import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Conduit.Combinators as C
import qualified Data.Conduit.Binary as CB
import qualified Data.Conduit.List as CL
import qualified Data.Conduit.Zlib as C
import qualified Data.Conduit as C
import Data.Conduit (($=), ($$), (=$=), (=$))
import Data.Conduit.Async ((=$=&), ($$&))
import qualified Data.Vector as V
import           Control.DeepSeq (NFData(..))

import Data.IORef
import System.IO
import System.Directory
import Data.Maybe
import Data.List (find)
import GHC.Conc                 (getNumCapabilities)

import Utils.Utils
import Substrim
import Language
import FileManagement
import Output
import Modules
import NGLess
import Data.Sam
import Data.FastQ

import Interpretation.Map
import Interpretation.Count
import Interpretation.FastQ
import Interpretation.Write
import Interpretation.Select
import Interpretation.Unique
import Utils.Conduit


{- Interpretation is done inside 3 and a half monads
 -  1. InterpretationEnvIO
 -      This is the NGLessIO monad with a variable environment on top
 -  2. InterpretationEnv
 -      This is the read-write variable environment
 -  3. InterpretationROEnv
 -      This is a read-only variable environment.
 -  3½. Either NGError
 -      Pure functions are in the 'Either NGError' monad
 - 
 - Monad (1) is a superset of (2) which is a superset of (3). runInEnv and
 - friends switch between the monads.
 -
 - For blocks, we have a special system where block-variables are read-write,
 - but others are read-only.
 -
 - Functions inside the interpret monads are named interpret*, helper
 - non-monadic functions which perform computations are named eval*.
 -
 -}


data NGLInterpretEnv = NGLInterpretEnv
    { ieModules :: [Module]
    , ieVariableEnv :: Map.Map T.Text NGLessObject
    }

type InterpretationEnvT m =
                (StateT NGLInterpretEnv m)
-- Monad 1: IO + read-write environment
type InterpretationEnvIO = InterpretationEnvT NGLessIO
-- Monad 2: read-write environment
type InterpretationEnv = InterpretationEnvT (ExceptT NGError Identity)
-- Monad 3: read-only environment
type InterpretationROEnv = ExceptT NGError (Reader NGLInterpretEnv)

{- The result of a block is a status indicating why the block finished
 - and the value of all block variables.
 -}
data BlockStatus = BlockOk | BlockDiscarded | BlockContinued
    deriving (Eq,Show)
data BlockResult = BlockResult
                { blockStatus :: BlockStatus
                , blockValues :: [(T.Text, NGLessObject)]
                } deriving (Eq,Show)

autoComprehendNB f (NGOList es) args = NGOList <$> sequence [f e args | e <- es]
autoComprehendNB f e args = f e args

-- Set line number
setlno :: Int -> InterpretationEnvIO ()
setlno !n = liftIO $ setOutputLno (Just n)

lookupVariable :: T.Text -> InterpretationROEnv (Maybe NGLessObject)
lookupVariable !k = (liftM2 (<|>))
    (lookupConstant k)
    (Map.lookup k . ieVariableEnv <$> ask)

lookupConstant :: T.Text -> InterpretationROEnv (Maybe NGLessObject)
lookupConstant !k = do
    constants <- concat . map modConstants . ieModules <$> ask
    case filter ((==k) . fst) constants of
        [] -> return Nothing
        [(_,v)] -> return (Just v)
        _ -> throwShouldNotOccur $ T.concat ["Multiple hits found for constant ", k]



setVariableValue :: T.Text -> NGLessObject -> InterpretationEnvIO ()
setVariableValue !k !v = modify $ \(NGLInterpretEnv mods e) -> (NGLInterpretEnv mods (Map.insert k v e))

getName (FuncName f) = f

findFunction :: FuncName -> InterpretationEnvIO (NGLessObject -> KwArgsValues -> NGLessIO NGLessObject)
findFunction fname = do
        mods <- gets ieModules
        case filter hasF mods of
            [m] -> do
                let Just func = find ((== fname) . funcName) (modFunctions m)
                    wrap = if funcAllowsAutoComprehension func
                                then autoComprehendNB
                                else id
                return $ wrap $ (runFunction m) (getName fname)
            [] -> throwShouldNotOccur $ T.concat ["Function '", getName fname, "' not found (not builtin and not in any loaded module)"]
            ms -> throwShouldNotOccur $ T.concat (["Function '", T.pack $ show fname, "' found in multiple modules! ("] ++ [T.concat [modname, ":"] | modname <- modName . modInfo <$> ms])
    where
        hasF m = (fname `elem` (funcName `fmap` modFunctions m))

runInterpretationRO :: NGLInterpretEnv -> InterpretationROEnv a -> Either NGError a
runInterpretationRO env act = runReader (runExceptT act) env

runInEnv :: InterpretationEnv a -> InterpretationEnvIO a
runInEnv act = do
    env <- gets id
    let Identity r = runExceptT (runStateT act env)
    case r of
        Left e -> throwError e
        Right (v, env') -> do
            put env'
            return v

runInROEnv :: InterpretationROEnv a -> InterpretationEnv a
runInROEnv action = do
    env <- gets id
    case runInterpretationRO env action of
        Left e -> throwError e
        Right v -> return v

runInROEnvIO :: InterpretationROEnv a -> InterpretationEnvIO a
runInROEnvIO = runInEnv . runInROEnv

runEitherInROEnv :: Either NGError a -> InterpretationROEnv a
runEitherInROEnv (Right v) = return v
runEitherInROEnv (Left err) = throwError err

runNGLessIO :: NGLessIO a -> InterpretationEnvIO a
runNGLessIO act = do
    r <- liftResourceT (runExceptT act)
    case r of
        Right val -> return val
        Left err -> throwError err

-- | By necessity, this code has several unreachable corners

unreachable :: ( MonadError NGError m) => String -> m a
unreachable err = throwShouldNotOccur ("Reached code that was thought to be unreachable!\n"++err)
nglTypeError err = throwShouldNotOccur ("Unexpected type error! This should have been caught by validation!\n"++err)

traceExpr m e =
    runNGLessIO $ outputListLno' TraceOutput ["Interpreting [", m , "]: ", show e]

interpret :: [Module] -> [(Int,Expression)] -> NGLessIO ()
interpret modules es = do
    evalStateT (interpretIO $ es) (NGLInterpretEnv modules Map.empty)
    outputListLno InfoOutput Nothing ["Interpretation finished."]

interpretIO :: [(Int, Expression)] -> InterpretationEnvIO ()
interpretIO es = forM_ es $ \(ln,e) -> do
    setlno ln
    traceExpr "interpretIO" e
    interpretTop e

interpretTop :: Expression -> InterpretationEnvIO ()
interpretTop (Assignment (Variable var) val) = traceExpr "assignment" val >> interpretTopValue val >>= setVariableValue var
interpretTop (FunctionCall f e args b) = void $ topFunction f e args b
interpretTop (Condition c ifTrue ifFalse) = do
    c' <- runInROEnvIO (interpretExpr c >>= boolOrTypeError "interpreting if condition")
    interpretTop (if c'
        then ifTrue
        else ifFalse)
interpretTop (Sequence es) = forM_ es interpretTop
interpretTop _ = throwShouldNotOccur ("Top level statement is NOP" :: String)

interpretTopValue :: Expression -> InterpretationEnvIO NGLessObject
interpretTopValue (FunctionCall f e args b) = topFunction f e args b
interpretTopValue e = runInROEnvIO (interpretExpr e)

interpretExpr :: Expression -> InterpretationROEnv NGLessObject
interpretExpr (Lookup (Variable v)) = lookupVariable v >>= \case
        Nothing -> throwScriptError ("Variable lookup error" :: String)
        Just r' -> return r'
interpretExpr (BuiltinConstant (Variable "STDIN")) = return (NGOString "/dev/stdin")
interpretExpr (BuiltinConstant (Variable "STDOUT")) = return (NGOString "/dev/stdout")
interpretExpr (BuiltinConstant (Variable v)) = throwShouldNotOccur ("Unknown builtin constant '" ++ show v ++ "': it should not have been accepted.")
interpretExpr (ConstStr t) = return (NGOString t)
interpretExpr (ConstBool b) = return (NGOBool b)
interpretExpr (ConstSymbol s) = return (NGOSymbol s)
interpretExpr (ConstInt n) = return (NGOInteger n)
interpretExpr (ConstDouble n) = return (NGODouble n)
interpretExpr (UnaryOp op v) = do
    v' <- interpretExpr v
    runEitherInROEnv (_evalUnary op v')
interpretExpr (BinaryOp bop v1 v2) = do
    v1' <- interpretExpr v1
    v2' <- interpretExpr v2
    runEitherInROEnv (_evalBinary bop v1' v2')
interpretExpr (IndexExpression expr ie) = do
    expr' <- interpretExpr expr
    ie' <- interpretIndex ie
    runEitherInROEnv (_evalIndex expr' ie')
interpretExpr (ListExpression e) = NGOList <$> mapM interpretExpr e
interpretExpr (MethodCall met self arg args) = do
    self' <- interpretExpr self
    arg' <- maybeInterpretExpr arg
    args' <- interpretArguments args
    executeMethod met self' arg' args'
interpretExpr not_expr = throwShouldNotOccur ("Expected an expression, received " ++ show not_expr)

interpretIndex :: Index -> InterpretationROEnv [Maybe NGLessObject]
interpretIndex (IndexTwo a b) = forM [a,b] maybeInterpretExpr
interpretIndex (IndexOne a) = forM [Just a] maybeInterpretExpr

maybeInterpretExpr :: Maybe Expression -> InterpretationROEnv (Maybe NGLessObject)
maybeInterpretExpr Nothing = return Nothing
maybeInterpretExpr (Just e) = Just <$> interpretExpr e

topFunction :: FuncName -> Expression -> [(Variable, Expression)] -> Maybe Block -> InterpretationEnvIO NGLessObject
topFunction (FuncName "preprocess") expr@(Lookup (Variable varName)) args (Just block) = do
    expr' <- runInROEnvIO $ interpretExpr expr
    args' <- runInROEnvIO $ interpretArguments args
    res' <- executePreprocess expr' args' block
    setVariableValue varName res'
    return res'
topFunction (FuncName "preprocess") expr _ _ = throwShouldNotOccur ("preprocess expected a variable holding a NGOReadSet, but received: " ++ show expr)
topFunction f expr args block = do
    expr' <- interpretTopValue expr
    args' <- runInROEnvIO $ interpretArguments args
    topFunction' f expr' args' block

topFunction' :: FuncName -> NGLessObject -> KwArgsValues -> Maybe Block -> InterpretationEnvIO NGLessObject
topFunction' (FuncName "fastq")     expr args Nothing = runNGLessIO (executeFastq expr args)
topFunction' (FuncName "group")     expr args Nothing = runNGLessIO (executeGroup expr args)
topFunction' (FuncName "samfile")   expr args Nothing = autoComprehendNB executeSamfile expr args
topFunction' (FuncName "unique")    expr args Nothing = runNGLessIO (executeUnique expr args)
topFunction' (FuncName "write")     expr args Nothing = traceExpr "write" expr >> runNGLessIO (executeWrite expr args)
topFunction' (FuncName "map")       expr args Nothing = runNGLessIO (executeMap expr args)
topFunction' (FuncName "select")    expr args Nothing = runNGLessIO (executeSelect expr args)
topFunction' (FuncName "count")     expr args Nothing = runNGLessIO (executeCount expr args)
topFunction' (FuncName "print")     expr args Nothing = executePrint expr args
topFunction' (FuncName "paired")   mate1 args Nothing = runNGLessIO (executePaired mate1 args)
topFunction' (FuncName "select")    expr args (Just b) = executeSelectWBlock expr args b
topFunction' fname@(FuncName fname') expr args Nothing = do
    traceExpr ("executing module function: '"++T.unpack fname'++"'") expr
    execF <- findFunction fname
    runNGLessIO (execF expr args)

topFunction' f _ _ _ = throwShouldNotOccur . concat $ ["Interpretation of ", (show f), " is not implemented"]

executeSamfile expr@(NGOString fname) args = do
    traceExpr "samfile" expr
    gname <- lookupStringOrScriptErrorDef (return fname) "samfile group name" "name" args
    return $ NGOMappedReadSet gname (T.unpack fname) Nothing
executeSamfile e args = unreachable ("executeSamfile " ++ show e ++ " " ++ show args)

data PreprocessPairOutput = Pair ShortRead ShortRead | Single ShortRead
instance NFData PreprocessPairOutput where
    rnf (Pair a b) = rnf a `seq` rnf b
    rnf (Single a) = rnf a


vMapMaybeLifted :: (a -> Either e (Maybe b)) -> V.Vector a -> Either e (V.Vector b)
vMapMaybeLifted f v = sequence $ V.unfoldr loop 0
    where
        loop i
            | i < V.length v = let !n = i+1 in
                            case f (v V.! i) of
                                Right Nothing -> loop n
                                Right (Just val) -> Just (Right val, n)
                                Left err -> Just (Left err, n)
            | otherwise = Nothing

inlineQCIf False _ = C.awaitForever C.yield -- identity conduit
inlineQCIf True resVar = C.passthroughSink (C.transPipe runNGLessIO (getPairedLines $= fqStatsC)) (liftIO . writeIORef resVar . Just)

executePreprocess :: NGLessObject -> [(T.Text, NGLessObject)] -> Block -> InterpretationEnvIO NGLessObject
executePreprocess (NGOList e) args _block = NGOList <$> mapM (\x -> executePreprocess x args _block) e
executePreprocess (NGOReadSet (ReadSet1 enc file)) args (Block [Variable var] block) = do
        runNGLessIO $ outputListLno' DebugOutput ["Preprocess on ", file]
        (newfp, h) <- runNGLessIO $ openNGLTempFile file "preprocessed_" "fq.gz"
        qcInput <- lookupBoolOrScriptErrorDef (return False) "preprocess" "__qc_input" args
        qcPre <- liftIO $ newIORef (Nothing :: Maybe FQStatistics)
        qcPost <- liftIO $ newIORef (Nothing :: Maybe FQStatistics)

        env <-gets id
        numCapabilities <- liftIO getNumCapabilities
        let mapthreads = max 1 (numCapabilities - 1)
        (conduitPossiblyCompressedFile file
            =$= linesC
            =$= inlineQCIf qcInput qcPre
            =$= fqConduitR enc
            =$= C.conduitVector 8192)
            =$=& (asyncMapEitherC mapthreads (vMapMaybeLifted ((liftM (liftM $ fqEncode enc)) . runInterpretationRO env . interpretPBlock1 block var))
                    =$= (C.concat :: C.Conduit (V.Vector B.ByteString) InterpretationEnvIO B.ByteString)
                    =$= C.passthroughSink (C.transPipe runNGLessIO (linesC =$= getPairedLines =$= fqStatsC)) (liftIO . writeIORef qcPost . Just)
                    =$= C.conduitVector 4000
                    )
                $$& (
                    (C.concat :: C.Conduit (V.Vector B.ByteString) InterpretationEnvIO B.ByteString)
                    =$= C.gzip =$ C.sinkHandle h)
        liftIO (hClose h)
        when qcInput $ do
            Just qcPreStats <- liftIO $ readIORef qcPre
            runNGLessIO $ outputFQStatistics file qcPreStats enc
        Just qcPostStats <- liftIO $ readIORef qcPost
        runNGLessIO $ outputFQStatistics (file ++ "-preprocessed") qcPostStats enc
        return (NGOReadSet $ ReadSet1 enc newfp)

executePreprocess (NGOReadSet (ReadSet2 enc fp1 fp2)) _args block = executePreprocess (NGOReadSet (ReadSet3 enc fp1 fp2 "")) _args block
executePreprocess (NGOReadSet (ReadSet3 enc fp1 fp2 fp3)) args (Block [Variable var] block) = do
        keepSingles <- runNGLessIO $ lookupBoolOrScriptErrorDef (return True) "preprocess argument" "keep_singles" args
        qcInput <- lookupBoolOrScriptErrorDef (return False) "preprocess" "__qc_input" args

        runNGLessIO $ outputListLno' DebugOutput (["Preprocess on paired end ",
                                                fp1, " + ", fp2] ++ (if fp3 /= ""
                                                                    then [" with singles ", fp3]
                                                                    else []))
        (fp1', out1) <- runNGLessIO $ openNGLTempFile fp1 "preprocessed.1." ".fq.gz"
        (fp2', out2) <- runNGLessIO $ openNGLTempFile fp2 "preprocessed.2." ".fq.gz"
        (fps, out3) <- runNGLessIO $ openNGLTempFile fp1 "preprocessed.singles." ".fq.gz"

        qcPre1 <- liftIO $ newIORef (Nothing :: Maybe FQStatistics)
        qcPre2 <- liftIO $ newIORef (Nothing :: Maybe FQStatistics)
        qcPre3 <- liftIO $ newIORef (Nothing :: Maybe FQStatistics)

        let rs1 :: C.Source InterpretationEnvIO ShortRead
            rs1 = conduitPossiblyCompressedFile fp1 =$= linesC =$= inlineQCIf qcInput qcPre1 =$= fqConduitR enc

            rs2 :: C.Source InterpretationEnvIO ShortRead
            rs2 = conduitPossiblyCompressedFile fp2 =$= linesC =$= inlineQCIf qcInput qcPre2 =$= fqConduitR enc

            rs3 :: C.Source InterpretationEnvIO ShortRead
            rs3 = if fp3 /= ""
                    then conduitPossiblyCompressedFile fp3 =$= linesC =$= inlineQCIf qcInput qcPre3 =$= fqConduitR enc
                    else C.yieldMany []

            write :: Handle -> InterpretationEnvIO (C.Sink ShortRead InterpretationEnvIO ((),FQStatistics))
            write h = do
                sink <- asyncGzipTo h
                return $ zipSink2
                        (fqEncodeC enc =$= sink)
                        (CL.map (\(ShortRead _ bps qs) -> (ByteLine bps, ByteLine qs)) =$= C.transPipe runNGLessIO fqStatsC)

            filter1 = CL.mapMaybe (\case
                            Pair sr _ -> Just sr
                            _ -> Nothing)
            filter2 = CL.mapMaybe (\case
                            Pair _ sr -> Just sr
                            _ -> Nothing)
            filterS = CL.mapMaybe (\case
                            Single sr -> Just sr
                            _ -> Nothing)

        env <- gets id
        numCapabilities <- liftIO getNumCapabilities
        let mapthreads = max 1 (numCapabilities - 2)
        w1 <- write out1
        w2 <- write out2
        wS <- write out3
        [((),s1),((),s2),((),s3)] <-
            (zipSource2 rs1 rs2
                =$= C.conduitVector 4096)
                $$& (asyncMapEitherC mapthreads (vMapMaybeLifted (runInterpretationRO env . intercalate keepSingles))
                    =$= (C.concat :: C.Conduit (V.Vector PreprocessPairOutput) InterpretationEnvIO PreprocessPairOutput)
                    =$= C.sequenceSinks
                        [ filter1 =$= w1
                        , filter2 =$= w2
                        , filterS =$= wS
                        ])
        wS' <- write out3
        ((),s3') <- rs3
                =$= preprocBlock
                =$= filterS
                =$= C.conduitVector 4096
                $$& ((C.concat :: C.Conduit (V.Vector ShortRead) InterpretationEnvIO ShortRead)
                =$= wS')
        let n3 = nSeq s3
            n3' = nSeq s3'
            anySingle = n3 > 0 || n3' > 0
        liftIO $ forM_ [out1, out2, out3] hClose
        unless anySingle
            (liftIO $ removeFile fps)
        forM_ (zip [qcPre1, qcPre2, qcPre3] [fp1, fp2, fp3]) $ \(q,fp) ->
            liftIO (readIORef q) >>= \case
                Nothing -> return ()
                Just qcPreStats -> runNGLessIO $ outputFQStatistics fp qcPreStats enc

        runNGLessIO $ outputLno' DebugOutput "Preprocess finished"
        return . NGOReadSet $ if anySingle
                    then ReadSet3 enc fp1' fp2' fps
                    else ReadSet2 enc fp1' fp2'
    where
        preprocBlock :: C.Conduit ShortRead InterpretationEnvIO PreprocessPairOutput
        preprocBlock = CL.mapMaybeM $ \r -> do
            r' <- runInROEnvIO $ interpretPBlock1 block var r
            return (Single <$> r')


        intercalate :: Bool -> (ShortRead, ShortRead) -> InterpretationROEnv (Maybe PreprocessPairOutput)
        intercalate keepSingles (r1, r2) = do
                r1' <- interpretPBlock1 block var r1
                r2' <- interpretPBlock1 block var r2
                return $ case (r1',r2') of
                    (Just r1'', Just r2'') -> Just (Pair r1'' r2'')
                    (Just r, Nothing) -> if keepSingles
                                                then Just (Single r)
                                                else Nothing
                    (Nothing, Just r) -> if keepSingles
                                                then Just (Single r)
                                                else Nothing
                    (Nothing, Nothing) -> Nothing
executePreprocess v _ _ = unreachable ("executePreprocess: Cannot handle this input: " ++ show v)

executeMethod :: MethodName -> NGLessObject -> Maybe NGLessObject -> [(T.Text, NGLessObject)] -> InterpretationROEnv NGLessObject
executeMethod method (NGOMappedRead samline) arg kwargs = runNGLess (executeMappedReadMethod method samline arg kwargs)
executeMethod m self arg kwargs = throwShouldNotOccur ("Method " ++ show m ++ " with self="++show self ++ " arg="++ show arg ++ " kwargs="++show kwargs ++ " is not implemented")


interpretPBlock1 :: Expression -> T.Text -> ShortRead -> InterpretationROEnv (Maybe ShortRead)
interpretPBlock1 block var r = do
    r' <- interpretBlock1 [(var, NGOShortRead r)] block
    case blockStatus r' of
        BlockDiscarded -> return Nothing -- Discard Read.
        _ -> case lookup var (blockValues r') of
                Just (NGOShortRead rr) -> case srLength rr of
                    0 -> return Nothing
                    _ -> return (Just rr)
                _ -> nglTypeError ("Expected variable "++show var++" to contain a short read.")

executePrint :: NGLessObject -> [(T.Text, NGLessObject)] -> InterpretationEnvIO NGLessObject
executePrint (NGOString s) [] = liftIO (T.putStr s) >> return NGOVoid
executePrint err  _ = throwScriptError ("Cannot print " ++ show err)

executeSelectWBlock :: NGLessObject -> [(T.Text, NGLessObject)] -> Block -> InterpretationEnvIO NGLessObject
executeSelectWBlock input@NGOMappedReadSet{ nglSamFile= fname} [] (Block [Variable var] body) = do
        runNGLessIO $ outputListLno' TraceOutput ["Executing blocked select on file ", fname]
        (oname, ohandle) <- runNGLessIO $ openNGLTempFile fname "block_selected_" "sam"
        readSamGroupsAsConduit fname
            $= C.mapM filterGroup
            =$= CL.concat
            =$= C.unlinesAscii
            $$ CB.sinkHandle ohandle
        liftIO $ hClose ohandle
        return input { nglSamFile = oname }
    where
        filterGroup :: [(SamLine, B.ByteString)] -> InterpretationEnvIO [B.ByteString]
        filterGroup [] = return []
        filterGroup [(SamHeader _, line)] = return [line]
        filterGroup mappedreads  = do
                    let _ = mappedreads :: [(SamLine, B.ByteString)]
                    mrs' <- runInROEnvIO (interpretBlock1 [(var, NGOMappedRead (map fst mappedreads))] body)
                    if blockStatus mrs' `elem` [BlockContinued, BlockOk]
                        then case lookup var (blockValues mrs') of
                            Just (NGOMappedRead []) -> return []
                            Just (NGOMappedRead rs) -> return (filterMappedRead mappedreads rs)
                            _ -> nglTypeError ("Expected variable "++show var++" to contain a mapped read.")

                        else return []
        filterMappedRead :: [(SamLine, B.ByteString)] -> [SamLine] -> [B.ByteString]
        filterMappedRead [] _ = []
        filterMappedRead _ [] = []
        filterMappedRead ((r0,rl):rs) (r':rs')
            | r' == r0 = rl:(filterMappedRead rs rs')
            | otherwise = filterMappedRead rs (r':rs')

executeSelectWBlock _ _ _ = unreachable ("Select with block")


interpretArguments :: [(Variable, Expression)] -> InterpretationROEnv [(T.Text, NGLessObject)]
interpretArguments = mapM interpretArguments'
    where interpretArguments' (Variable v, e) = do
            e' <- interpretExpr e
            return (v,e')

interpretBlock :: [(T.Text, NGLessObject)] -> [Expression] -> InterpretationROEnv BlockResult
interpretBlock vs [] = return (BlockResult BlockOk vs)
interpretBlock vs (e:es) = do
    r <- interpretBlock1 vs e 
    case blockStatus r of
        BlockOk -> interpretBlock (blockValues r) es
        _ -> return r

interpretBlock1 :: [(T.Text, NGLessObject)] -> Expression -> InterpretationROEnv BlockResult
interpretBlock1 vs (Assignment (Variable n) val) = do
    val' <- interpretBlockExpr vs val
    if n `notElem` (map fst vs)
        then throwShouldNotOccur ("only assignments to block variable are possible [assigning to '"++show n++"']")
        else do
            let vs' = map (\p@(a,_) -> (if a == n then (a,val') else p)) vs
            return $ BlockResult BlockOk vs'
interpretBlock1 vs Discard = return (BlockResult BlockDiscarded vs)
interpretBlock1 vs Continue = return (BlockResult BlockContinued vs)
interpretBlock1 vs (Condition c ifT ifF) = do
    NGOBool v' <- interpretBlockExpr vs c
    interpretBlock1 vs (if v' then ifT else ifF)
interpretBlock1 vs (Sequence expr) = interpretBlock vs expr -- interpret [expr]
interpretBlock1 vs x = unreachable ("interpretBlock1: This should not have happened " ++ show vs ++ " " ++ show x)

interpretBlockExpr :: [(T.Text, NGLessObject)] -> Expression -> InterpretationROEnv NGLessObject
interpretBlockExpr vs val = local (\(NGLInterpretEnv mods e) -> (NGLInterpretEnv mods (Map.union e (Map.fromList vs)))) (interpretPreProcessExpr val)

interpretPreProcessExpr :: Expression -> InterpretationROEnv NGLessObject
interpretPreProcessExpr (FunctionCall (FuncName "substrim") var args _) = do
    NGOShortRead r <- interpretExpr var
    args' <- interpretArguments args
    let mq = lookupWithDefault (NGOInteger 0) "min_quality" args'
    mq' <- getInt mq
    return . NGOShortRead $ substrim mq' r

interpretPreProcessExpr expr = interpretExpr expr

getInt (NGOInteger i) = return (fromInteger i)
getInt o = nglTypeError ("getInt: Argument type must be NGOInteger (got " ++ show o ++ ").")


_evalUnary :: UOp -> NGLessObject -> Either NGError NGLessObject
_evalUnary UOpMinus (NGOInteger n) = return $ NGOInteger (-n)
_evalUnary UOpLen (NGOShortRead r) = return $ NGOInteger . toInteger $ srLength r
_evalUnary UOpNot (NGOBool v) = return $ NGOBool (not v)
_evalUnary op v = nglTypeError ("invalid unary operation ("++show op++") on value " ++ show v)

_evalIndex :: NGLessObject -> [Maybe NGLessObject] -> Either NGError NGLessObject
_evalIndex (NGOList elems) [Just (NGOInteger ix)] = return (elems !! fromInteger ix)
_evalIndex sr index@[Just (NGOInteger a)] = _evalIndex sr $ (Just $ NGOInteger (a + 1)) : index
_evalIndex (NGOShortRead (ShortRead rId rSeq rQual)) [Just (NGOInteger s), Nothing] =
    return . NGOShortRead $ ShortRead rId (B.drop (fromIntegral s) rSeq) (B.drop (fromIntegral s) rQual)
_evalIndex (NGOShortRead (ShortRead rId rSeq rQual)) [Nothing, Just (NGOInteger e)] =
    return . NGOShortRead $ ShortRead rId (B.take (fromIntegral e) rSeq) (B.take (fromIntegral e) rQual)

_evalIndex (NGOShortRead (ShortRead rId rSeq rQual)) [Just (NGOInteger s), Just (NGOInteger e)] = do
    let e' = fromIntegral e
        s' = fromIntegral s
        e'' = e'- s'
    return $ NGOShortRead (ShortRead rId (B.take e'' . B.drop s' $ rSeq) (B.take e'' . B.drop s' $ rQual))
_evalIndex _ _ = nglTypeError ("_evalIndex: invalid operation" :: String)


-- Binary Evaluation
_evalBinary :: BOp ->  NGLessObject -> NGLessObject -> Either NGError NGLessObject
_evalBinary BOpLT (NGOInteger a) (NGOInteger b) = Right $ NGOBool (a < b)
_evalBinary BOpGT (NGOInteger a) (NGOInteger b) = Right $ NGOBool (a > b)
_evalBinary BOpLTE (NGOInteger a) (NGOInteger b) = Right $ NGOBool (a <= b)
_evalBinary BOpGTE (NGOInteger a) (NGOInteger b) = Right $ NGOBool (a >= b)
_evalBinary BOpEQ lexpr rexpr = Right . NGOBool $ lexpr == rexpr
_evalBinary BOpNEQ lexpr rexpr = Right . NGOBool $ lexpr /= rexpr
_evalBinary BOpAdd (NGOInteger a) (NGOInteger b) = Right $ NGOInteger (a + b)
_evalBinary BOpAdd (NGOString a) (NGOString b) = Right $ NGOString (T.concat [a, b])
_evalBinary BOpMul (NGOInteger a) (NGOInteger b) = Right $ NGOInteger (a * b)
_evalBinary op a b = throwScriptError (concat ["_evalBinary: ", show op, " ", show a, " ", show b])

