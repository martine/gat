-- | \"git log\"-like commit history output.
module Log (
    LogOptions(..), defaultLogOptions
  , printLog
) where

import qualified Data.ByteString as B
import Data.List
import Control.Monad.Error

import Color
import Commit
import Diff
import Object
import ObjectStore
import Shared
import State

-- | Options for printLog.
data LogOptions = LogOptions {
    logoptions_limit :: Int              -- ^ Number of commits to show.
  , logoptions_filter :: Commit -> Bool  -- ^ Show only commits passing a test.
  , logoptions_filelist :: Bool          -- ^ Show a list of modified files, too.
}
-- | Default LogOptions settings.
defaultLogOptions = LogOptions (-1) (const True) False

getCommitOrFail :: Hash -> GitM Commit
getCommitOrFail hash = do
  commit <- getObject hash
  case commit of
    ObCommit commit -> return commit
    _ -> fail $ "hash " ++ hashAsHex hash ++ " not a commit?"

-- | Driver for \"gat log\" -- display a log with various options set.
printLog :: LogOptions -> Hash -> GitM ()
printLog opts hash = do
  commit <- getCommitOrFail hash
  printLogCommit opts hash commit

printLogCommit :: LogOptions -> Hash -> Commit -> GitM ()
printLogCommit (LogOptions {logoptions_limit=0}) hash commit = return ()
printLogCommit opts hash commit = do
  parent <-
    case commit_parents commit of
      (hashstr:_) -> do
        let hash = Hash (fromHex hashstr)
        parent <- getCommitOrFail hash
        return (Just (hash, parent))
      _ -> return Nothing
  opts' <-
    if logoptions_filter opts commit
      then do
        liftIO $ printCommit hash commit
        when (logoptions_filelist opts) $ do
          ObTree tree1 <- getObject $ Hash (fromHex (commit_tree commit))
          case parent of
            Just (_, pcommit) -> do
              ObTree tree2 <- getObject $ Hash (fromHex (commit_tree pcommit))
              liftIO $ printFileList tree1 tree2
            Nothing ->
              liftIO $ printFileList tree1 (Tree [])
        return $ opts { logoptions_limit=logoptions_limit opts - 1 }
      else return opts
  case parent of
    Nothing -> return ()
    Just (hash, commit) -> printLogCommit opts' hash commit

-- | Pring a single Commit in a form similar to "git log".
printCommit :: Hash -> Commit -> IO ()
printCommit hash commit = do
  putStrLn $ coloredLine Yellow $ "commit " ++ hashAsHex hash
  when (length (commit_parents commit) > 1) $
    putStrLn $ "Parents: " ++ intercalate " " (commit_parents commit)
  putStrLn $ "Author: " ++ commit_author commit
  putStrLn ""
  printMessage (commit_message commit)

printMessage :: B.ByteString -> IO ()
printMessage msg = mapM_ printIndentedLine (B.split 10 msg) where
  printIndentedLine :: B.ByteString -> IO ()
  printIndentedLine str = do
    putStr "    "
    B.putStrLn str

printFileList :: Tree -> Tree -> IO ()
printFileList tree1 tree2 = do
  diff <- diffTrees tree2 tree1
  forM_ diff $ \(left, right) -> do
    case (left, right) of
      (DiffItem {di_path=l}, DiffItem {di_path=r}) | l == r ->
        putStrLn $ "M\t" ++ di_path left
      (DiffItem {di_hash=(Just emptyhash)}, _) ->
        putStrLn $ "A\t" ++ di_path right
      (_, DiffItem {di_hash=(Just emptyhash)}) ->
        putStrLn $ "D\t" ++ di_path left
      _ -> fail $ "something funky with " ++ show (di_path left, di_path right)
  putStrLn ""
