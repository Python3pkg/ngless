{- Copyright 2013-2015 NGLess Authors
 - License: MIT
 -}
{-# LANGUAGE DeriveDataTypeable, OverloadedStrings #-}
module Main
    ( main
    ) where

import Interpret
import Validation
import ValidationNotPure
import Language
import Tokens
import Types
import Parse
import Configuration
import ReferenceDatabases
import Output

import Data.Maybe
import Control.Monad
import Control.Applicative
import Control.Concurrent
import System.Console.CmdArgs
import System.FilePath.Posix
import System.Directory

import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Encoding as T
import qualified Data.ByteString as B


data NGLess =
        DefaultMode
              { debug_mode :: String
              , input :: String
              , script :: Maybe String
              , print_last :: Bool
              , n_threads :: Int
              , output_directory :: Maybe FilePath
              , temporary_directory :: Maybe FilePath
              , keep_temporary_files :: Bool
              }
        | InstallGenMode
              { input :: String}
           deriving (Eq, Show, Data, Typeable)

ngless = DefaultMode
        { debug_mode = "ngless"
        , input = "-" &= argPos 0 &= opt ("-" :: String)
        , script = Nothing &= name "e"
        , print_last = False &= name "p"
        , n_threads = 1 &= name "n"
        , output_directory = Nothing &= name "o"
        , temporary_directory = Nothing
        , keep_temporary_files = False
        }
        &= details  [ "Example:" , "ngless script.ngl" ]


installargs = InstallGenMode
        { input = "Reference" &= argPos 0
        }
        &= name "--install-reference-data"
        &= details  [ "Example:" , "(sudo) ngless --install-reference-data sacCer3" ]

-- | outputDebug implements the debug-mode argument.
-- The only purpose is to aid in debugging by printing intermediate
-- representations.
outputDebug :: String -> String -> Bool -> T.Text -> IO ()
outputDebug "ast" fname reqversion text = case parsengless fname reqversion text >>= validate of
            Left err -> T.putStrLn (T.concat ["Error in parsing: ", err])
            Right sc -> print . nglBody $ sc

outputDebug "tokens" fname _reqversion text = case tokenize fname text of
            Left err -> T.putStrLn err
            Right toks -> print . map snd $ toks

outputDebug emode _ _ _ = putStrLn (concat ["Debug mode '", emode, "' not known"])


wrapPrint (Script v sc) = Script v (wrap sc)
    where
        wrap [] = []
        wrap [e] = [addPrint e]
        wrap (e:es) = e:wrap es
        addPrint (lno,e) = (lno,FunctionCall Fwrite e [(Variable "ofile", BuiltinConstant (Variable "STDOUT"))] Nothing)

optsExec :: NGLess -> IO ()
optsExec opts@DefaultMode{} = do
    let fname = input opts
    let reqversion = isNothing $ script opts
    setNumCapabilities (n_threads opts)
    case (output_directory opts, fname) of
        (Nothing,"") -> setOutputDirectory "STDIN.output_ngless"
        (Nothing,_) -> setOutputDirectory (fname ++ ".output_ngless")
        (Just odir, _) -> setOutputDirectory odir
    setTemporaryDirectory (temporary_directory opts)
    setKeepTemporaryFiles (keep_temporary_files opts)
    odir <- outputDirectory
    createDirectoryIfMissing False odir
    --Note that the input for ngless is always UTF-8.
    --Always. This means that we cannot use T.readFile
    --which is locale aware.
    --We also assume that the text file is quite small and, therefore, loading
    --it in to memory is not resource intensive.
    engltext <- case script opts of
        Just s -> return . Right . T.pack $ s
        _ -> T.decodeUtf8' <$> (if fname == "-" then B.getContents else B.readFile fname)
    
    case engltext of
        Left err -> print err
        Right ngltext 
            | debug_mode opts `elem` ["ast", "tokens"] ->
                outputDebug (debug_mode opts) fname reqversion ngltext
            |otherwise -> do
                let maybe_add_print = Right . (if print_last opts then wrapPrint else id)
                case parsengless fname reqversion ngltext >>= maybe_add_print >>= checktypes >>= validate of
                    Left err -> T.putStrLn err
                    Right sc -> do
                        when (uses_STDOUT `any` [e | (_,e) <- nglBody sc]) $
                            whenNormal (setVerbosity Quiet)
                        outputLno' DebugOutput "Validating script..."
                        errs <- validate_io sc
                        case errs of
                            Nothing -> do
                                outputLno' InfoOutput "Script OK. Starting interpretation..."
                                interpret fname ngltext (nglBody sc)
                                writeOutput (odir </> "output.js") fname ngltext
                            Just errors -> T.putStrLn (T.concat errors)


-- if user uses the flag -i he will install a Reference Genome to all users
optsExec (InstallGenMode ref)
    | isDefaultReference ref = void $ installData Nothing ref
    | otherwise =
        error (concat ["Reference ", ref, " is not a known reference."])

getModes :: Mode (CmdArgs NGLess)
getModes = cmdArgsMode $ modes [ngless &= auto, installargs]
    &= verbosity
    &= summary sumtext
    &= help "ngless implement the NGLess language"
    where sumtext = concat ["ngless v", versionStr, "(C) NGLess Authors 2013-2015"]

main = cmdArgsRun getModes >>= optsExec
