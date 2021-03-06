
import qualified Data.ByteString.Lazy as BL
import Control.Monad.Error
import Control.Exception
import Data.List
import System.Console.GetOpt
import System.Environment
import System.Exit
import System.IO
import Text.Printf

import Commit
import Diff
import Index
import Log
import Object
import ObjectStore
import Pack
import Pager
import Refs
import RevParse
import Shared
import State

cmdRef :: [String] -> GitM ()
cmdRef args = do
  unless (length args == 1) $
    fail "'ref' takes one argument"
  let [name] = args
  hash <- resolveRev name
  liftIO $ print hash

cmdCat :: [String] -> GitM ()
cmdCat args = do
  (raw, name) <-
    case getOpt Permute options args of
      (opts, [name], []) -> return (not (null opts), name)
      (_,    _,      []) ->
        fail "expect 1 argument: name of object to cat"
      (_,    _,    errs) -> fail $ concat errs ++ usage
  hash <- resolveRev name
  case hash of
    Left err -> fail err
    Right hash ->
      if raw
        then do
          (typ, obj) <- getRawObject hash
          redirectThroughPager $ liftIO $ BL.putStr obj
        else getObject hash >>= redirectThroughPager . liftIO . print
  where
    usage = usageInfo "gat cat [options] <object name>" options
    options = [
      Option "" ["raw"] (NoArg True) "dump raw object bytes"
      ]

cmdDumpIndex :: [String] -> GitM ()
cmdDumpIndex args = liftIO $ do
  unless (length args == 0) $
    fail "'dump-index' takes no arguments"
  index <- loadIndex
  forM_ (in_entries index) $ \e -> do
    printf "%s %o %s\n" (show $ ie_mode e) (ie_realMode e) (ie_name e)
  print (in_tree index)

cmdDiffIndex :: [String] -> GitM ()
cmdDiffIndex args = do
  unless (length args == 0) $
    fail "'diff-index' takes no arguments"
  index <- liftIO loadIndex
  pairs <- liftIO $ diffAgainstIndex index
  redirectThroughPager $ mapM_ showDiff pairs

cmdDiff :: [String] -> GitM ()
cmdDiff args = do
  diffpairs <-
    case args of
      [] -> do
        tree <- revTree "HEAD"
        liftIO $ diffAgainstTree tree
      [name] -> do
        tree <- revTree name
        liftIO $ diffAgainstTree tree
      [name1,name2] -> do
        tree1 <- revTree name1
        tree2 <- revTree name2
        liftIO $ diffTrees tree1 tree2
  redirectThroughPager $ mapM_ showDiff diffpairs
  where
    revTree :: String -> GitM Tree
    revTree name = do
      hash <- resolveRev name >>= forceError
      findTree hash

cmdDumpTree args = do
  unless (length args == 1) $
    fail "expects one arg"
  tree <- resolveRev (head args) >>= forceError >>= findTree
  redirectThroughPager $ liftIO $ print tree

cmdDumpPackIndex args = do
  unless (length args == 1) $
    fail "expects one arg"
  redirectThroughPager $ liftIO $ dumpPackIndex (head args)

cmdLog :: [String] -> GitM ()
cmdLog args = do
  (opts, args) <-
    case getOpt Permute options args of
      (o, a, []) -> return (foldl (flip id) defaultLogOptions o, a)
      (_, _, errs) -> fail $ concat errs ++ usage
  commithash <- do
    commitish <- case args of
      [x] -> return x
      [] ->  return "HEAD"
      _ -> fail "expects zero or one arg"
    resolveRev commitish >>= forceError
  redirectThroughPager $ printLog opts commithash
  where
    usage = usageInfo "gat log [options] [startpoint]" options
    options = [
        Option "n" ["limit"]
        (ReqArg (\n opts -> opts { logoptions_limit=(read n) }) "LIMIT")
        "limit number of commits to show"
      , Option "" ["author"]
        (ReqArg (\author opts -> opts { logoptions_filter=authorFilter author })
         "AUTHOR")
        "show only commits by particular author"
      , Option "l" ["name-status"]
        (NoArg (\opts -> opts { logoptions_filelist=True }))
        "show files changed in each commit"
      ]
    authorFilter author commit =
      author `isInfixOf` commit_author commit

commands = [
    ("cat",  cmdCat)
  , ("diff-index", cmdDiffIndex)
  , ("diff", cmdDiff)
  , ("log", cmdLog)
  , ("ref",  cmdRef)
  , ("dump-index", cmdDumpIndex)
  , ("dump-pack-index", cmdDumpPackIndex)
  , ("dump-tree", cmdDumpTree)
  ]

usage message = do
  hPutStrLn stderr $ "Error: " ++ message ++ "."
  hPutStrLn stderr $ "Commands:"
  forM_ commands $ \(name, _) ->
    hPutStrLn stderr $ "  " ++ name
  return (ExitFailure 1)

main = do
  argv <- getArgs
  exit <- do
    case argv of
      (cmd:args) -> do
        case lookup cmd commands of
          Just cmdfunc -> do
            catchJust userErrors
              (do runGit (cmdfunc args); return ExitSuccess)
              (\err -> do putStrLn $ "fatal: " ++ err; return (ExitFailure 1))
          _ -> usage $ "unknown command: '" ++ cmd ++ "'"
      _ -> usage $ "must provide command"
  exitWith exit
