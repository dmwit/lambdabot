{-# LANGUAGE PatternGuards #-}
-- Copyright (c) 2005 Donald Bruce Stewart - http://www.cse.unsw.edu.au/~dons
-- GPL version 2 or later (see http://www.gnu.org/copyleft/gpl.html)

-- Written: Mon Dec 12 10:16:56 EST 2005

-- | A binding to Djinn.
module Lambdabot.Plugin.Djinn (theModule) where

import Lambdabot.Config.Core
import Lambdabot.Plugin

import Data.Char
import Data.List
import Data.Maybe
import System.Process (readProcess)
import Text.Regex.TDFA

-- | We can accumulate an interesting environment
type DjinnEnv = ([Decl] {- prelude -}, [Decl])
type Djinn = ModuleT DjinnEnv LB
type Decl = String

theModule :: Module ([Decl], [Decl])
theModule = newModule
    { moduleSerialize = Nothing

    -- this means djinn better be visible at boot time
    , moduleDefState = do
        binary  <- getConfig djinnBinary
        st      <- io $ getDjinnEnv binary ([],[]) -- get the prelude
        return (either (const []) snd{-!-} st, [])

    , moduleCmds = return
        [ (command "djinn")
            { help = mapM_ say
                [ "djinn <type>."
                , "Generates Haskell code from a type."
                , "http://darcs.augustsson.net/Darcs/Djinn"
                ]
            , process = rejectingCmds djinnCmd
            }
        , (command "djinn-add")
            { help = do
                say "djinn-add <expr>."
                say "Define a new function type or type synonym"
            , process = rejectingCmds djinnAddCmd
            }
        , (command "djinn-del")
            { help = do
                say "djinn-del <ident>."
                say "Remove a symbol from the environment"
            , process = rejectingCmds djinnDelCmd
            }
        , (command "djinn-env")
            { help = do
                say "djinn-env."
                say "Show the current djinn environment"
            , process = const djinnEnvCmd
            }
        , (command "djinn-names")
            { help = do
                say "djinn-names."
                say "Show the current djinn environment, compactly."
            , process = const djinnNamesCmd
            }
        , (command "djinn-clr")
            { help = do
                say "djinn-clr."
                say "Reset the djinn environment"
            , process = const djinnClrCmd
            }
        , (command "djinn-ver")
            { help = do
                say "djinn-ver."
                say "Show current djinn version"
            , process = const djinnVerCmd
            }
        ]
    }

-- check the args, reject them if they start with a colon (ignoring whitespace)
rejectingCmds :: Monad m => ([Char] -> Cmd m ()) -> [Char] -> Cmd m ()
rejectingCmds action args
    | take 1 (dropWhile isSpace args) == ":"
                = say "Invalid command"
    | otherwise = action args

-- Normal commands
djinnCmd :: [Char] -> Cmd Djinn ()
djinnCmd s = do
        (_,env) <- readMS
        binary  <- getConfig djinnBinary
        e       <- io $ djinn binary env $ ":set +sorted\nf ? " ++ dropForall s
        mapM_ say $ either id (parse . lines) e
    where
      dropForall t = maybe t mrAfter (t =~~ re)
      re = "^forall [[:alnum:][:space:]]+\\."
      parse :: [String] -> [String]
      parse x = if length x < 2
                then ["No output from Djinn; installed?"]
                else tail x

-- Augment environment. Have it checked by djinn.
djinnAddCmd :: [Char] -> Cmd Djinn ()
djinnAddCmd s = do
    (p,st)  <- readMS
    binary  <- getConfig djinnBinary
    est     <- io $ getDjinnEnv binary (p, dropSpace s : st)
    case est of
        Left e     -> say (head e)
        Right st'' -> writeMS st''

-- Display the environment
djinnEnvCmd :: Cmd Djinn ()
djinnEnvCmd = do
    (prelude,st) <- readMS
    mapM_ say $ prelude ++ st

-- Display the environment's names (quarter-baked)
djinnNamesCmd :: Cmd Djinn ()
djinnNamesCmd = do
    (prelude,st) <- readMS
    let names = concat $ intersperse " " $ concatMap extractNames $ prelude ++ st
    say names
  where extractNames = filter (isUpper . head) . unfoldr (\x -> case x of _:_ -> listToMaybe (lex x); _ -> Nothing)

-- Reset the env
djinnClrCmd :: Cmd Djinn ()
djinnClrCmd = modifyMS (flip (,) [] . fst)

-- Remove sym from environment. We let djinn do the hard work of
-- looking up the symbols.
djinnDelCmd :: [Char] -> Cmd Djinn ()
djinnDelCmd s =  do
    (_,env) <- readMS
    binary  <- getConfig djinnBinary
    eenv <- io $ djinn binary env $ ":delete " ++ dropSpace s ++ "\n:environment"
    case eenv of
        Left e     -> say (head e)
        Right env' -> modifyMS $ \(prel,_) ->
            (prel,filter (`notElem` prel) . nub . lines $ env')

-- Version number
djinnVerCmd :: Cmd Djinn ()
djinnVerCmd = do
    binary <- getConfig djinnBinary
    say =<< io (getDjinnVersion binary)

getDjinnVersion :: String -> IO String
getDjinnVersion binary = fmap (extractVersion . head . lines) (readProcess binary [] ":q")
    where extractVersion str = case str =~~ "version [0-9]+(-[0-9]+)*" of
            Nothing -> "Unknown"
            Just m  -> m


------------------------------------------------------------------------

-- | Extract the default environment
getDjinnEnv :: String -> DjinnEnv -> IO (Either [String] DjinnEnv)
getDjinnEnv binary (prel,env') = do
    env <- djinn binary env' ":environment"
    case env of
        Left e  -> return $ Left e
        Right o -> do let new = filter (\p -> p `notElem` prel) . nub .  lines $ o
                      return $ Right (prel, new)

-- | Call the binary:

djinn :: String -> [Decl] -> String -> IO (Either [String] String)
djinn binary env' src = do
    let env = concat . intersperse "\n" $ env'
    out <- readProcess binary [] (unlines [env, src, ":q"])
    let safeInit [] = []
        safeInit xs = init xs
        o = dropNL . clean_ . unlines . safeInit . drop 2 . lines $ out
    return $ case () of {_
        | o =~ "Cannot parse command" ||
          o =~ "cannot be realized"   ||
          o =~ "^Error:"                -> Left (lines o)
        | otherwise                     -> Right o
    }

--
-- Clean up djinn output
--
clean_ :: String -> String
clean_ s | Just mr <- s =~~ prompt  = mrBefore mr ++ mrAfter mr
         | otherwise                = s
    where
        prompt = "(Djinn> *)+"
