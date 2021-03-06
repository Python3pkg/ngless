{- Copyright 2013-2017 NGLess Authors
 - License: MIT
 -}
{-# LANGUAGE TemplateHaskell, CPP #-}
module FileManagement
    ( InstallMode(..)
    , createTempDir
    , openNGLTempFile
    , openNGLTempFile'
    , removeFileIfExists
    , removeIfTemporary
    , setupHtmlViewer
    , takeBaseNameNoExtensions
    , samtoolsBin
    , megahitBin
    , bwaBin
    ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Codec.Archive.Tar as Tar
import qualified Codec.Archive.Tar.Entry as Tar
import qualified Codec.Compression.GZip as GZip
import System.FilePath
import Control.Monad
import System.Posix.Files (setFileMode)
import System.Posix.Internals (c_getpid)

import Data.FileEmbed (embedDir)
import Output
import System.Directory
import System.IO
import System.IO.Error
import Control.Exception
import System.Environment (getExecutablePath, lookupEnv)
import Control.Monad.Trans.Resource
import Control.Monad.IO.Class (liftIO)

import Configuration

import NGLess.NGLEnvironment
import NGLess.NGError
import Dependencies.Embedded
import Utils.LockFile


data InstallMode = User | Root deriving (Eq, Show)

-- | open a temporary file
-- This respects the preferences of the user (using the correct temporary
-- directory and deleting the file when necessary)
--
-- These files will be auto-removed when ngless exits
openNGLTempFile' :: FilePath -> String -> String -> NGLessIO (ReleaseKey, (FilePath, Handle))
openNGLTempFile' base prefix ext = do
    tdir <- nConfTemporaryDirectory <$> nglConfiguration
    liftIO $ createDirectoryIfMissing True tdir
    keepTempFiles <- nConfKeepTemporaryFiles <$> nglConfiguration
    let cleanupAction = if not keepTempFiles
                then deleteTempFile
                else hClose . snd
    (key,(fp,h)) <- allocate
                (openTempFileWithDefaultPermissions tdir (prefix ++ takeBaseNameNoExtensions base ++ "." ++ ext))
                cleanupAction
    outputListLno' DebugOutput ["Created & opened temporary file ", fp]
    updateNglEnvironment $ \e -> e { ngleTemporaryFilesCreated = fp:(ngleTemporaryFilesCreated e) }
    return (key,(fp,h))

-- | Open a temporary file
-- See openNGLTempFile'
openNGLTempFile :: FilePath -> String -> String -> NGLessIO (FilePath, Handle)
openNGLTempFile base pre ext = snd <$> openNGLTempFile' base pre ext

deleteTempFile (fp, h) = do
    hClose h
    removeFileIfExists fp

-- | removeIfTemporary removes files if (and only if):
-- 1. this was a temporary file created by 'openNGLTempFile'
-- 2. the user has not requested that temporary files be kept
--
-- It is *not necessary* to call this function, but it may save on temporary
-- disk space to clean up early.
removeIfTemporary :: FilePath -> NGLessIO ()
removeIfTemporary fp = do
    keepTempFiles <- nConfKeepTemporaryFiles <$> nglConfiguration
    createdFiles <- ngleTemporaryFilesCreated <$> nglEnvironment
    unless (keepTempFiles || fp `notElem` createdFiles) $ do
        outputListLno' DebugOutput ["Removing temporary file: ", fp]
        liftIO $ removeFileIfExists fp
        updateNglEnvironment $ \e -> e { ngleTemporaryFilesCreated = filter (==fp) (ngleTemporaryFilesCreated e) }


-- | This is a version of 'takeBaseName' which drops all extension
-- ('takeBaseName' only takes out the first extension
takeBaseNameNoExtensions = dropExtensions . takeBaseName

-- | create a temporary directory as a sub-directory of the user-specified
-- temporary directory.
--
-- Releasing deletes the directory and all its contents (unless the user
-- requested that temporary files be preserved).
createTempDir :: String -> NGLessIO (ReleaseKey,FilePath)
createTempDir template = do
        tbase <- nConfTemporaryDirectory <$> nglConfiguration
        liftIO $ createDirectoryIfMissing True tbase
        keepTempFiles <- nConfKeepTemporaryFiles <$> nglConfiguration
        allocate
            (c_getpid >>= createFirst tbase (takeBaseNameNoExtensions template))
            (if not keepTempFiles
                then removeDirectoryRecursive
                else const (return ()))
    where
        createFirst :: (Num a, Show a) => FilePath -> String -> a -> IO FilePath
        createFirst dirbase t n = do
            let dirpath = dirbase </> t <.> "tmp" ++ show n
            try (createDirectory dirpath) >>= \case
                Right () -> return dirpath
                Left e
                    | isAlreadyExistsError e -> createFirst dirbase t (n + 1)
                    | otherwise -> ioError e

-- This is in IO because it is run after NGLessIO has finished.
setupHtmlViewer :: FilePath -> IO ()
setupHtmlViewer dst = do
    exists <- doesFileExist (dst </> "index.html")
    unless exists $ do
        createDirectoryIfMissing False dst
        createDirectoryIfMissing False (dst </> "htmllibs")
        createDirectoryIfMissing False (dst </> "fonts")
        createDirectoryIfMissing False (dst </> "forms")
        forM_ $(embedDir "Html") $ \(fp,bs) ->
            B.writeFile (dst </> fp) bs


-- | path to bwa
bwaBin :: NGLessIO FilePath
bwaBin = findOrCreateBin "NGLESS_BWA_BIN" bwaFname bwaData
    where
        bwaFname = "ngless-" ++ versionStr ++ "-bwa" ++ binaryExtension

-- | path to samtools
samtoolsBin :: NGLessIO FilePath
samtoolsBin = findOrCreateBin "NGLESS_SAMTOOLS_BIN" samtoolsFname samtoolsData
    where
        samtoolsFname = "ngless-" ++ versionStr ++ "-samtools" ++ binaryExtension

megahitBin :: NGLessIO FilePath
megahitBin = liftIO (lookupEnv "NGLESS_MEGAHIT_BIN") >>= \case
    Just bin -> checkExecutable "NGLESS_MEGAHIT_BIN" bin
    Nothing -> do
        path <- findBin "megahit"
        maybe createMegahitBin return path

createMegahitBin :: NGLessIO FilePath
createMegahitBin = do
    megahitData' <- liftIO megahitData
    destdir <- binPath User
    when (B.null megahitData') $
        throwSystemError "Cannot find megahit on the system and this is a build without embedded dependencies."
    withLockFile LockParameters
                { lockFname = destdir ++ ".megahit-expand"
                , maxAge = 300
                , whenExistsStrategy = IfLockedRetry { nrLockRetries = 37*60, timeBetweenRetries = 60 }
               } $ do
        outputListLno' TraceOutput ["Expanding megahit binaries into ", destdir]
        unpackMegahit destdir $ Tar.read . GZip.decompress $ BL.fromChunks [megahitData']
    return $ destdir </> "megahit"
    where
        unpackMegahit :: FilePath -> Tar.Entries Tar.FormatError -> NGLessIO ()
        unpackMegahit _ Tar.Done = return ()
        unpackMegahit _ (Tar.Fail err) = throwSystemError ("Error expanding megahit archive: " ++ show err)
        unpackMegahit destdir (Tar.Next e next) = do
            case Tar.entryContent e of
                Tar.NormalFile content _ -> do
                    let dest = destdir </> takeBaseName (Tar.entryPath e)
                    liftIO $ do
                        BL.writeFile dest content
                        --setModificationTime dest (posixSecondsToUTCTime (fromIntegral $ Tar.entryTime e))
                        setFileMode dest (Tar.entryPermissions e)
                Tar.Directory -> return ()
                _ -> throwSystemError ("Unexpected entry in megahit tarball: " ++ show e)
            unpackMegahit destdir next



copyDir ::  FilePath -> FilePath -> IO ()
copyDir src dst = do
  createDirectoryIfMissing False dst
  xs <- filter (`notElem` [".", ".."]) <$> getDirectoryContents src
  forM_ xs $ \n -> do
    exists <- doesDirectoryExist (src </> n)
    if exists
        then copyDir  (src </> n) (dst </> n)
        else copyFile (src </> n) (dst </> n)


binPath :: InstallMode -> NGLessIO FilePath
binPath Root = do
    nglessBinDirectory <- takeDirectory <$> liftIO getExecutablePath
#ifndef WINDOWS
    return (nglessBinDirectory </> "../share/ngless/bin")
#else
    return nglessBinDirectory
#endif
binPath User = ((</> "bin") . nConfUserDirectory) <$> nglConfiguration

findBin :: FilePath -> NGLessIO (Maybe FilePath)
findBin fname = do
        rootPath <- (</> fname) <$> binPath Root
        rootex <- liftIO $ canExecute rootPath
        if rootex then
            return (Just rootPath)
        else do
            userpath <- (</> fname) <$> binPath User
            userex <- liftIO $ canExecute userpath
            return $ if userex
                then Just userpath
                else Nothing
    where
        canExecute bin = do
            exists <- doesFileExist bin
            if exists
                then executable <$> getPermissions bin
                else return False

writeBin :: FilePath -> IO B.ByteString -> NGLessIO FilePath
writeBin fname bindata = do
    userBinPath <- binPath User
    bindata' <- liftIO bindata
    when (B.null bindata') $
        throwSystemError ("Cannot find " ++ fname ++ " on the system and this is a build without embedded dependencies.")
    liftIO $ do
        createDirectoryIfMissing True userBinPath
        let fname' = userBinPath </> fname
        B.writeFile fname' bindata'
        p <- getPermissions fname'
        setPermissions fname' (setOwnerExecutable True p)
        return fname'

findOrCreateBin :: String -> FilePath -> IO B.ByteString -> NGLessIO FilePath
findOrCreateBin envvar fname bindata = liftIO (lookupEnv envvar) >>= \case
    Just bin -> checkExecutable envvar bin
    Nothing -> do
        path <- findBin fname
        maybe (writeBin fname bindata) return path

checkExecutable :: String -> FilePath -> NGLessIO FilePath
checkExecutable name bin = do
    exists <- liftIO $ doesFileExist bin
    unless exists
        (throwSystemError $ concat [name, " binary not found!\n","Expected it at ", bin])
    is_executable <- executable <$> liftIO (getPermissions bin)
    unless is_executable
        (throwSystemError $ concat [name, " binary found at ", bin, ".\nHowever, it is not an executable file!"])
    return bin



binaryExtension :: String
#ifdef WINDOWS
binaryExtension = ".exe"
#else
binaryExtension = ""
#endif
