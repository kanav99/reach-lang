{-# OPTIONS_GHC -Wno-missing-export-lists #-}

module Reach.AST.Base where

import Control.Applicative ((<|>))
import Control.DeepSeq (NFData)
import Data.Aeson (encode)
import Data.Aeson.Types (ToJSON)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Internal (w2c)
import qualified Data.ByteString.Lazy as LB
import qualified Data.List as List
import qualified Data.Text as T
import GHC.Generics
import GHC.Stack (HasCallStack)
import Language.JavaScript.Parser
import Reach.JSOrphans ()
import Reach.Texty
import Reach.UnsafeUtil
import qualified System.Console.Pretty as TC
import Safe (atMay)
import Data.Maybe (fromMaybe)
import Reach.Util (makeErrCode)

--- Source Information
data ReachSource
  = ReachStdLib
  | ReachSourceFile FilePath
  deriving (Eq, Generic, NFData, Ord)

instance Show ReachSource where
  show ReachStdLib = "reach standard library"
  show (ReachSourceFile fp) = fp

data SrcLoc = SrcLoc (Maybe String) (Maybe TokenPosn) (Maybe ReachSource)
  deriving (Eq, Generic, NFData, Ord)

-- This is a "defaulting" instance where the left info is preferred,
-- but can fall back on the right if info is absent from the left.
instance Semigroup SrcLoc where
  SrcLoc mlab mpos msrc <> SrcLoc mlab' mpos' msrc' =
    SrcLoc (mlab <|> mlab') (mpos <|> mpos') (msrc <|> msrc')

instance Monoid SrcLoc where
  mempty = SrcLoc Nothing Nothing Nothing

instance Show SrcLoc where
  show (SrcLoc mlab mtp mrs) = concat $ List.intersperse ":" $ concat [sr, loc, lab]
    where
      lab = case mlab of
        Nothing -> []
        Just s -> [s]
      sr = case mrs of
        Nothing -> []
        Just s -> [show s]
      loc = case mtp of
        Nothing -> []
        Just (TokenPn _ l c) -> [show l, show c]

instance Pretty SrcLoc where
  pretty = viaShow

data ImpossibleError
  = Err_Impossible_InspectForall
  deriving (Eq, Ord, Generic, ErrorMessageForJson, ErrorSuggestions)

instance HasErrorCode ImpossibleError where
  errPrefix = const "RX"
  -- These indices are part of an external interface; they
  -- are used in the documentation of Error Codes.
  -- If you delete a constructor, do NOT re-allocate the number.
  -- Add new error codes at the end.
  errIndex = \case
    Err_Impossible_InspectForall -> 0

instance Show ImpossibleError where
  show = \case
    Err_Impossible_InspectForall ->
      "Cannot inspect value from `forall`"

instance Pretty ImpossibleError where
  pretty = viaShow

data CompilationError = CompilationError
  { ce_suggestions :: [String]
  , ce_errorMessage :: String
  , ce_position :: [Int]
  , ce_offendingToken :: Maybe String
  }
  deriving (Show, Generic, ToJSON)

class ErrorMessageForJson a where
  errorMessageForJson :: Show a => a -> String
  errorMessageForJson = show

class ErrorSuggestions a where
  errorSuggestions :: a -> (Maybe String, [String])
  errorSuggestions _ = (Nothing, [])

srcloc_line_col :: SrcLoc -> [Int]
srcloc_line_col (SrcLoc _ (Just (TokenPn _ l c)) _) = [l, c]
srcloc_line_col _ = []

getSrcLine :: Maybe Int -> [String] -> Maybe String
getSrcLine rowNum fl =
  rowNum >>= (\ r -> atMay fl $  r - 1)

errorCodeDocUrl :: HasErrorCode a => a -> String
errorCodeDocUrl e =
  "https://docs.reach.sh/" <> errCode e <> ".html"

expect_throw :: (HasErrorCode a, Show a, ErrorMessageForJson a, ErrorSuggestions a) => HasCallStack => Maybe ([SLCtxtFrame]) -> SrcLoc -> a -> b
expect_throw mCtx src ce =
  case unsafeIsErrorFormatJson of
    True ->
      error $
        "error: "
          ++ (map w2c $
                LB.unpack $
                  encode $
                    CompilationError
                      { ce_suggestions = snd $ errorSuggestions ce
                      , ce_offendingToken = fst $ errorSuggestions ce
                      , ce_errorMessage = errorMessageForJson ce
                      , ce_position = srcloc_line_col src
                      })
    False -> do
      let hasColor = unsafeTermSupportsColor
      let color c = if hasColor then TC.color c else id
      let style s = if hasColor then TC.style s else id
      let fileLines = srcloc_file src >>= Just . unsafeReadFile
      let rowNum = case srcloc_line_col src of
                  [l, _] -> Just l
                  _ -> Nothing
      let rowNumStr = maybe "" (style TC.Bold . color TC.Cyan . show) rowNum
      let fileLine = maybe "" (\ l -> " " <> rowNumStr <> "| " <> style TC.Faint l <> "\n")
                      $ getSrcLine rowNum (fromMaybe [] fileLines)
      error . T.unpack . unsafeRedactAbs . T.pack $
        style TC.Bold (color TC.Red "error") <> "[" <> style TC.Bold (errCode ce) <> "]: " <> (take 512 $ show ce) <> "\n\n" <>
          " " <> style TC.Bold (show src) ++ "\n\n"
          <> fileLine
          <> case concat mCtx of
            [] -> ""
            ctx -> "\n" <> style TC.Bold "Trace" <> ":\n" <> List.intercalate "\n" (topOfStackTrace ctx) <> "\n"
          <> "\nFor further explanation of this error, see: " <> style TC.Underline (errorCodeDocUrl ce) <> "\n"

expect_thrown :: (HasErrorCode a, Show a, ErrorMessageForJson a, ErrorSuggestions a) => HasCallStack => SrcLoc -> a -> b
expect_thrown = expect_throw Nothing

topOfStackTrace :: [SLCtxtFrame] -> [String]
topOfStackTrace stack
  | length stackMsgs > 10 = take 10 stackMsgs <> ["  ..."]
  | otherwise = stackMsgs
  where
    stackMsgs = map getStackTraceMessage stack

-- Mimic Node's stack trace message
getStackTraceMessage :: SLCtxtFrame -> String
getStackTraceMessage (SLC_CloApp call_at clo_at name) =
  "  in " <> maybe "[unknown function]" show name <> " from (" <> show clo_at <> ")" <> " at (" <> show call_at <> ")"

srcloc_builtin :: SrcLoc
srcloc_builtin = SrcLoc (Just "<builtin>") Nothing Nothing

srcloc_top :: SrcLoc
srcloc_top = SrcLoc (Just "<top level>") Nothing Nothing

srcloc_src :: ReachSource -> SrcLoc
srcloc_src rs = SrcLoc Nothing Nothing (Just rs)

get_srcloc_src :: SrcLoc -> ReachSource
get_srcloc_src (SrcLoc _ _ (Just rs)) = rs
get_srcloc_src (SrcLoc _ _ Nothing) = ReachSourceFile "src" -- FIXME

srcloc_at :: String -> (Maybe TokenPosn) -> SrcLoc -> SrcLoc
srcloc_at lab mp (SrcLoc _ _ rs) = SrcLoc (Just lab) mp rs

srcloc_file :: SrcLoc -> Maybe FilePath
srcloc_file = \case
  SrcLoc _ _ (Just (ReachSourceFile f)) -> Just f
  _ -> Nothing

class SrcLocOf a where
  srclocOf :: a -> SrcLoc

srclocOf_ :: SrcLocOf a => SrcLoc -> a -> SrcLoc
srclocOf_ def v = a'
  where
    a = srclocOf v
    a' = if a == srcloc_builtin then def else a

--- Security Levels
data SecurityLevel
  = Secret
  | Public
  deriving (Eq, Generic, NFData, Show)

public :: a -> (SecurityLevel, a)
public x = (Public, x)

secret :: a -> (SecurityLevel, a)
secret x = (Secret, x)

instance Pretty SecurityLevel where
  pretty = \case
    Public -> "public"
    Secret -> "secret"

instance Semigroup SecurityLevel where
  Secret <> _ = Secret
  _ <> Secret = Secret
  Public <> Public = Public

lvlMeet :: SecurityLevel -> (SecurityLevel, a) -> (SecurityLevel, a)
lvlMeet lvl (lvl', x) = (lvl <> lvl', x)

instance Monoid SecurityLevel where
  mempty = Public

--- Static Language
type SLVar = String

type SLPart = B.ByteString

render_sp :: SLPart -> Doc
render_sp = viaShow

data PrimOp
  = ADD
  | SUB
  | MUL
  | DIV
  | MOD
  | PLT
  | PLE
  | PEQ
  | PGE
  | PGT
  | IF_THEN_ELSE
  | DIGEST_EQ
  | ADDRESS_EQ
  | TOKEN_EQ
  | SELF_ADDRESS
  | LSH
  | RSH
  | BAND
  | BIOR
  | BXOR
  | BYTES_CONCAT
  deriving (Eq, Generic, NFData, Ord, Show)

instance Pretty PrimOp where
  pretty = \case
    ADD -> "+"
    SUB -> "-"
    MUL -> "*"
    DIV -> "/"
    MOD -> "%"
    PLT -> "<"
    PLE -> "<="
    PEQ -> "=="
    PGE -> ">="
    PGT -> ">"
    IF_THEN_ELSE -> "ite"
    DIGEST_EQ -> "=="
    ADDRESS_EQ -> "=="
    TOKEN_EQ -> "=="
    SELF_ADDRESS -> "selfAddress"
    LSH -> "<<"
    RSH -> ">>"
    BAND -> "&"
    BIOR -> "|"
    BXOR -> "^"
    BYTES_CONCAT -> "concat"

data SLCtxtFrame
  = SLC_CloApp SrcLoc SrcLoc (Maybe SLVar)
  deriving (Eq, Ord, Generic, NFData)

instance Show SLCtxtFrame where
  show (SLC_CloApp call_at clo_at mname) =
    "at " ++ show call_at ++ " call to " ++ name ++ " (defined at: " ++ show clo_at ++ ")"
    where
      name = maybe "[unknown function]" show mname

instance SrcLocOf SLCtxtFrame where
  srclocOf (SLC_CloApp at _ _) = at

class Generic a => HasErrorCode a where
  errPrefix :: a -> String
  errIndex :: a -> Int
  errCode :: a -> String
  errCode e = makeErrCode (errPrefix e) (errIndex e)
