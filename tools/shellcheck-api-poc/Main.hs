{-# LANGUAGE OverloadedStrings #-}
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Deliberately restricted to the existing reproducer, not a general CLI.
module Main (main) where

import Control.Exception (IOException, evaluate, try)
import Control.Monad (forM)
import Data.Aeson (Value, encode, object, (.=))
import qualified Data.ByteString.Lazy.Char8 as B
import ShellCheck.Checker (checkScript)
import ShellCheck.Interface
import System.Directory (doesFileExist)
import System.Exit (ExitCode(..), exitWith)
import System.FilePath (normalise)

files :: [FilePath]
files = ["lmline/policy.bash", "lmline/config.bash", "lmline/validation-boundary.bash"]

-- These sources use explicit source=lmline/... annotations, resolved from
-- the repository working directory. No source-path or external-sources
-- overrides are supported by this deliberately closed reproducer adapter.
-- Like the CLI without -x, only command-line inputs (and /dev/null) may be
-- sourced. Read failures are returned to ShellCheck, not silently discarded.
readSource :: Maybe Bool -> FilePath -> IO (Either String String)
readSource external path
  | external /= Nothing = ioError $ userError "Reproducer adapter does not support external-sources directives"
  | normalise path `elem` ("/dev/null" : files) = do
      result <- try $ do
        text <- readFile path
        _ <- evaluate (length text)
        return text
      return $ either (Left . show) Right (result :: Either IOException String)
  | otherwise = return $ Left "Not following: not specified as input (use -x)."

system :: String -> SystemInterface IO
system rc = SystemInterface
  { siReadFile = readSource
  , siFindSource = \_ external sourcePaths name ->
      if external /= Nothing
        then ioError $ userError "Reproducer adapter does not support external-sources directives"
        else if null sourcePaths
          then return name
          else ioError $ userError "Reproducer adapter does not support source-path directives"
  , siGetConfig = \_ -> return $ Just (".shellcheckrc", rc)
  }

level :: Severity -> String
level ErrorC = "error"
level WarningC = "warning"
level InfoC = "info"
level StyleC = "style"

diagnostic :: PositionedComment -> Value
diagnostic pc = object
  [ "file" .= posFile start, "line" .= posLine start
  , "column" .= posColumn start, "endLine" .= posLine end
  , "endColumn" .= posColumn end, "level" .= level (cSeverity comment)
  , "code" .= cCode comment, "message" .= cMessage comment
  ]
  where
    start = pcStartPos pc
    end = pcEndPos pc
    comment = pcComment pc

main :: IO ()
main = do
  rc <- readFile ".shellcheckrc"
  -- Fail rather than accidentally implementing different source-path policy
  -- if the reproducer's configuration grows beyond its current disable list.
  let settings = filter (\s -> not (null s) && head s /= '#') (lines rc)
  if all (\s -> take 8 s == "disable=") settings
    then return ()
    else ioError $ userError "Reproducer adapter supports only disable= rc settings"
  comments <- forM files $ \file -> do
    exists <- doesFileExist file
    if exists then return () else ioError $ userError "Missing reproducer input"
    text <- readFile file
    result <- checkScript (system rc) emptyCheckSpec
      { csFilename = file
      , csScript = text
      , csShellTypeOverride = Just Bash
      }
    return $ crComments result
  let allComments = concat comments
  B.putStrLn $ encode $ map diagnostic allComments
  exitWith $ if null allComments then ExitSuccess else ExitFailure 1
