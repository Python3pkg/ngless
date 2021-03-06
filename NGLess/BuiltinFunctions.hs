{- Copyright 2013-2017 NGLess Authors
 - License: MIT
 -}
module BuiltinFunctions
    ( MethodName(..)
    , MethodInfo(..)
    , builtinFunctions
    , builtinMethods
    , findFunction
    ) where

import Data.List (find)
import Modules
import Language

data MethodInfo = MethodInfo
    { methodName :: MethodName
    , methodSelfType :: NGLType
    , methodArgType :: Maybe NGLType
    , methodReturnType :: NGLType
    , methodKwargsInfo :: [ArgInformation] -- Unnamed argument is called "__0"
    , methodIsPure :: Bool
    } deriving (Eq, Show)

findFunction :: [Module] -> FuncName -> Maybe Function
findFunction mods fn = find ((==fn) . funcName) $ builtinFunctions ++ concat (modFunctions <$> mods)

builtinFunctions =
    [Function (FuncName "fastq") (Just NGLString) [ArgCheckFileReadable] NGLReadSet fastqArgs False
    ,Function (FuncName "paired") (Just NGLString) [ArgCheckFileReadable] NGLReadSet pairedArgs False
    ,Function (FuncName "group") (Just (NGList NGLReadSet)) [] NGLReadSet groupArgs False
    ,Function (FuncName "samfile") (Just NGLString) [ArgCheckFileReadable] NGLMappedReadSet samfileArgs False
    ,Function (FuncName "unique") (Just NGLReadSet) [] NGLReadSet uniqueArgs False
    ,Function (FuncName "preprocess") (Just NGLReadSet) [] NGLVoid preprocessArgs False
    ,Function (FuncName "substrim") (Just NGLRead) [] NGLRead substrimArgs False
    ,Function (FuncName "endstrim") (Just NGLRead) [] NGLRead endstrimArgs False
    ,Function (FuncName "map") (Just NGLReadSet) [] NGLMappedReadSet mapArgs False
    ,Function (FuncName "mapstats") (Just NGLMappedReadSet) [] NGLCounts mapStatsArgs False
    ,Function (FuncName "select") (Just NGLMappedReadSet) [] NGLMappedReadSet selectArgs False
    ,Function (FuncName "count") (Just NGLMappedReadSet) [] NGLCounts countArgs False
    ,Function (FuncName "countfile") (Just NGLString) [ArgCheckFileReadable] NGLCounts [] False
    ,Function (FuncName "write") (Just NGLAny) [] NGLVoid writeArgs False
    ,Function (FuncName "print") (Just NGLAny) [] NGLVoid [] False
    ]

groupArgs =
    [ArgInformation "name" True NGLString []
    ]

writeArgs =
    [ArgInformation "ofile" True NGLString [ArgCheckFileWritable]
    ,ArgInformation "format" False NGLSymbol [ArgCheckSymbol ["tsv", "csv", "bam", "sam"]]
    ,ArgInformation "verbose" False NGLBool []
    ]

countArgs =
    [ArgInformation "features" False (NGList NGLString) []
    ,ArgInformation "min" False NGLInteger []
    ,ArgInformation "multiple" False NGLSymbol [ArgCheckSymbol ["all1", "dist1", "1overN", "unique_only"]]
    ,ArgInformation "mode" False NGLSymbol [ArgCheckSymbol ["union", "intersection_strict", "intersection_non_empty"]]
    ,ArgInformation "gff_file" False NGLString [ArgCheckFileReadable]
    ,ArgInformation "functional_map" False NGLString [ArgCheckFileReadable]
    ,ArgInformation "strand" False NGLBool []
    ,ArgInformation "norm" False NGLBool []
    ,ArgInformation "discard_zeros" False NGLBool []
    ,ArgInformation "include_minus1" False NGLBool []
    ,ArgInformation "normalization" False NGLSymbol [ArgCheckSymbol ["raw", "normed", "scaled", "fpkm"]]
    ]

selectArgs =
    [ArgInformation "keep_if" False (NGList NGLSymbol) [ArgCheckSymbol ["mapped", "unmapped", "unique"]]
    ,ArgInformation "drop_if" False (NGList NGLSymbol) [ArgCheckSymbol ["mapped", "unmapped", "unique"]]
    ,ArgInformation "paired" False NGLBool []
    ,ArgInformation "__oname" False NGLString []
    ]

fastqArgs =
    [ArgInformation "encoding" False NGLSymbol [ArgCheckSymbol ["auto", "33", "64", "sanger", "solexa"]]
    ,ArgInformation "__perform_qc" False NGLBool []
    ]

samfileArgs =
    [ArgInformation "name" False NGLString []
    ]
pairedArgs =
    [ArgInformation "second" True NGLString []
    ,ArgInformation "singles" False NGLString []
    ,ArgInformation "__perform_qc" False NGLBool []
    ]

uniqueArgs =
    [ArgInformation "max_copies" False NGLInteger []]

preprocessArgs =
    [ArgInformation "keep_singles" False NGLBool []
    ,ArgInformation "__qc_input" False NGLBool []
    ]

mapArgs =
    [ArgInformation "reference" False NGLString []
    ,ArgInformation "fafile" False NGLString [ArgCheckFileReadable]
    ,ArgInformation "mode_all" False NGLBool []
    ,ArgInformation "mapper" False NGLString []
    ,ArgInformation "__extra_bwa" False (NGList NGLString) []
    ,ArgInformation "__oname" False NGLString []
    ]

mapStatsArgs = []

substrimArgs =
    [ArgInformation "min_quality" True NGLInteger []
    ]

endstrimArgs =
    [ArgInformation "min_quality" True NGLInteger []
    ,ArgInformation "from_ends" False NGLSymbol [ArgCheckSymbol ["both", "3", "5"]]
    ]


builtinMethods =
    [MethodInfo (MethodName "flag")   NGLMappedRead (Just NGLSymbol) NGLBool flagArgs True
    ,MethodInfo (MethodName "filter") NGLMappedRead Nothing NGLMappedRead filterArgs True
    ,MethodInfo (MethodName "pe_filter") NGLMappedRead Nothing NGLMappedRead [] True
    ,MethodInfo (MethodName "some_match") NGLMappedRead (Just NGLString) NGLBool [] True
    ,MethodInfo (MethodName "unique") NGLMappedRead Nothing NGLMappedRead [] True
    ,MethodInfo (MethodName "avg_quality") NGLRead Nothing NGLDouble [] True
    ,MethodInfo (MethodName "fraction_at_least") NGLRead (Just NGLInteger) NGLDouble [] True
    ]

filterArgs =
    [ArgInformation "min_identity_pc" False NGLInteger []
    ,ArgInformation "min_match_size" False NGLInteger []
    ,ArgInformation "action" False NGLSymbol [ArgCheckSymbol ["drop", "unmatch"]]
    ,ArgInformation "reverse" False NGLBool []
    ]

flagArgs =
    [ArgInformation "__0" False NGLSymbol [ArgCheckSymbol ["mapped", "unmapped"]]
    ]
