{- Copyright 2015 NGLess Authors
 - License: MIT
 -}

{-# LANGUAGE TupleSections, OverloadedStrings #-}
module StandardModules.NGLStdlib
    ( loadStdlibModules
    ) where


import qualified StandardModules.Example as Example
import qualified StandardModules.Batch as Batch
import qualified ExternalModules as Ext
import Modules
import NGLess

loadStdlibModules :: [ModInfo] -> NGLessIO [Module]
loadStdlibModules = mapM loadModules1

loadModules1 (ModInfo "example" version) = Example.loadModule version
loadModules1 (ModInfo "batch" version) = Batch.loadModule version
loadModules1 (ModInfo "example-cmd" version) = Ext.loadModule "example-cmd" version
loadModules1 (ModInfo modname _) = throwScriptError ("Could not load module " ++show modname)

