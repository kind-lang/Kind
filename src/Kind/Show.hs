-- Rust info stringifier (for reference):

-- //./../../../kind2/src/info/mod.rs//

-- Rust highlight_error (for reference):

-- //./../../tmp_highlight.rs//

-- Haskell Types (for reference):

-- //./Type.hs//

module Kind.Show where

import Prelude hiding (EQ, LT, GT)

import Kind.Type
import Kind.Reduce
import Kind.Highlight as H

import System.IO (readFile)
import System.Directory (canonicalizePath)
import Control.Exception (try)

import qualified Data.Map.Strict as M
import qualified Data.IntMap.Strict as IM

import System.Console.ANSI


-- Stringification
-- ---------------

termShow :: Term -> Int -> String
termShow (All nam inp bod) dep =
  let nam' = nam
      inp' = termShow inp dep
      bod' = termShow (bod (Var nam dep)) (dep + 1)
  in concat ["∀(" , nam' , ": " , inp' , ") " , bod']
termShow (Lam nam bod) dep =
  let nam' = nam
      bod' = termShow (bod (Var nam dep)) (dep + 1)
  in concat ["λ" , nam' , " " , bod']
termShow (App fun arg) dep =
  let fun' = termShow fun dep
      arg' = termShow arg dep
  in concat ["(" , fun' , " " , arg' , ")"]
termShow (Ann chk val typ) dep =
  let val' = termShow val dep
      typ' = termShow typ dep
  in concat ["{" , val' , ": " , typ' , "}"]
termShow (Slf nam typ bod) dep =
  termShow typ dep
termShow (Ins val) dep =
  let val' = termShow val dep
  in concat ["~" , val']
termShow (Dat scp cts) dep =
  let scp' = unwords (map (\x -> termShow x dep) scp)
      cts' = unwords (map (\(Ctr nm fs rt) ->
        "#" ++ nm ++ "{" ++
        unwords (map (\(fn, ft) -> fn ++ ":" ++ termShow ft dep) fs) ++
        "} : " ++ termShow rt dep) cts)
  in concat ["#[", scp', "]{ ", cts', " }"]
termShow (Con nam arg) dep =
  let arg' = unwords (map (\x -> termShow x dep) arg)
  in concat ["#", nam, "{", arg', "}"]
termShow (Mat cse) dep =
  let cse' = unwords (map (\(cnm, cbod) -> "#" ++ cnm ++ ": " ++ termShow cbod dep) cse)
  in concat ["λ{ ", cse', " }"]
termShow (Ref nam) dep = nam
termShow (Let nam val bod) dep =
  let nam' = nam
      val' = termShow val dep
      bod' = termShow (bod (Var nam dep)) (dep + 1)
  in concat ["let " , nam' , " = " , val' , "; " , bod']
termShow (Use nam val bod) dep =
  let nam' = nam
      val' = termShow val dep
      bod' = termShow (bod (Var nam dep)) (dep + 1)
  in concat ["use " , nam' , " = " , val' , "; " , bod']
termShow Set dep = "*"
termShow U48 dep = "U48"
termShow (Num val) dep =
  let val' = show val
  in concat [val']
termShow (Op2 opr fst snd) dep =
  let opr' = operShow opr
      fst' = termShow fst dep
      snd' = termShow snd dep
  in concat ["(" , opr' , " " , fst' , " " , snd' , ")"]
termShow (Swi nam x z s p) dep =
  let nam' = nam
      x'   = termShow x dep
      z'   = termShow z dep
      s'   = termShow (s (Var (nam ++ "-1") dep)) (dep + 1)
      p'   = termShow (p (Var nam dep)) dep
  in concat ["switch " , nam' , " = " , x' , " { 0: " , z' , " _: " , s' , " }: " , p']
termShow (Txt txt) dep = concat ["\"" , txt , "\""]
termShow (Nat val) dep = show val
termShow (Hol nam ctx) dep = concat ["?" , nam]
termShow (Met uid spn) dep = concat ["(_", strSpn (reverse spn) dep, ")"]
termShow (Var nam idx) dep = nam
termShow (Src src val) dep = termShow val dep

strSpn :: [Term] -> Int -> String
strSpn []       dep = ""
strSpn (x : xs) dep = concat [" ", termShow x dep, strSpn xs dep]

operShow :: Oper -> String
operShow ADD = "+"
operShow SUB = "-"
operShow MUL = "*"
operShow DIV = "/"
operShow MOD = "%"
operShow EQ  = "=="
operShow NE  = "!="
operShow LT  = "<"
operShow GT  = ">"
operShow LTE = "<="
operShow GTE = ">="
operShow AND = "&"
operShow OR  = "|"
operShow XOR = "^"
operShow LSH = "<<"
operShow RSH = ">>"

contextShow :: Book -> Fill -> [Term] -> Int -> String
contextShow book fill []     dep = ""
contextShow book fill (x:xs) dep = concat [" " , contextShowAnn book fill x dep , contextShow book fill xs dep]

contextShowAnn :: Book -> Fill -> Term -> Int -> String
contextShowAnn book fill (Ann chk val typ) dep = concat ["{" , termShow (normal book fill 0 val dep) dep , ": " , termShow (normal book fill 0 typ dep) dep , "}"]
contextShowAnn book fill term              dep = termShow (normal book fill 0 term dep) dep


infoShow :: Book -> Fill -> Info -> IO String
infoShow book fill info = case info of
  Found nam typ ctx dep ->
    let msg = concat ["?", nam, " : ", termShow typ dep]
        ctx_str = contextShow book fill ctx dep
    in return $ concat ["\x1b[1mGOAL\x1b[0m ", msg, ctx_str]
  Error src exp det bad dep -> do
    let exp'  = concat ["- expected: \x1b[32m", termShow exp dep, "\x1b[0m"]
        det'  = concat ["- detected: \x1b[31m", termShow det dep, "\x1b[0m"]
        bad'  = concat ["- bad_term: \x1b[2m", termShow bad dep, "\x1b[0m"]
    (file, text) <- case src of
      Just (Cod (Loc fileName startLine startCol) (Loc _ endLine endCol)) -> do
        canonicalPath <- resolveToAbsolutePath fileName
        content <- readSourceFile canonicalPath
        let highlighted = H.highlightError (startLine, startCol) (endLine, endCol) content
        return (canonicalPath, highlighted)
      Nothing -> return ("unknown_file", "Could not read source file.")
    let src' = concat ["\x1b[4m", file, "\x1b[0m\n", text]
    return $ concat ["\x1b[1mERROR:\x1b[0m\n", exp', "\n", det', "\n", bad', "\n", src']
  Solve nam val dep ->
    return $ concat ["SOLVE: _", show nam, " = ", termShow val dep]
  Vague nam ->
    return $ concat ["VAGUE: _", nam]
  Print val dep ->
    return $ termShow val dep

readSourceFile :: FilePath -> IO String
readSourceFile file = do
  result <- try (readFile file) :: IO (Either IOError String)
  case result of
    Right content -> return content
    Left _ -> do
      result2 <- try (readFile (file ++ "/_.kind2")) :: IO (Either IOError String)
      return $ either (const "Could not read source file.") id result2

resolveToAbsolutePath :: FilePath -> IO FilePath
resolveToAbsolutePath relativePath = do
    absPath <- canonicalizePath relativePath
    return absPath
