-- Checker:
-- //./Type.hs//

module Kind.CompileJS where

import Kind.Check
import Kind.Env
import Kind.Equal
import Kind.Reduce
import Kind.Show
import Kind.Type
import Kind.Util

import Control.Monad (forM)
import Data.List (intercalate)
import Data.Maybe (fromJust)
import Data.Word
import qualified Control.Monad.State.Lazy as ST
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import qualified Data.Set as S

import Debug.Trace

import Prelude hiding (EQ, LT, GT)

-- Type
-- ----

-- Compilable Term
data CT
  = CNul
  | CLam String (CT -> CT)
  | CApp CT CT
  | CCon String [(String, CT)]
  | CMat CT [(String, [String], CT)]
  | CRef String
  | CLet String CT (CT -> CT)
  | CNum Word64
  | CFlt Double
  | COp2 Oper CT CT
  | CSwi CT CT
  | CLog CT CT
  | CVar String Int
  | CTxt String
  | CLst [CT]
  | CNat Integer

data FN
  = FN [String] CT

type ArityMap
  = M.Map String Int

-- Transformations
-- ---------------

-- Converts a Term into a Compilable Term
-- Uses type information to:
-- - Ensure constructor fields are present
-- - Annotate Mat cases with the field names
termToCT :: Book -> Fill -> Term -> Maybe Term -> Int -> CT
termToCT book fill term typx dep = bindCT (t2ct term typx dep) [] where
  t2ct term typx dep = go term where
    go (Lam nam bod) =
      let bod' = \x -> t2ct (bod (Var nam dep)) Nothing (dep+1)
      in CLam nam bod'
    go (App fun arg) =
      let fun' = t2ct fun Nothing dep
          arg' = t2ct arg Nothing dep
      in CApp fun' arg'
    go (Ann _ val typ) =
      t2ct val (Just typ) dep
    go (Slf _ _ _) =
      CNul
    go (Ins val) =
      t2ct val typx dep
    go (ADT _ _ _) =
      CNul
    go (Con nam arg) =
      case lookup nam (getADTCts (reduce book fill 2 (fromJust typx))) of
        Just (Ctr _ tele) ->
          let fNames = getTeleNames tele dep []
              fields = map (\ (f,t) -> (f, t2ct t Nothing dep)) $ zip fNames (map snd arg)
          in CCon nam fields
        Nothing -> error $ "constructor-not-found:" ++ nam
    go (Mat cse) =
      case reduce book fill 2 (fromJust typx) of
        (All _ adt _) ->
          let adt' = reduce book fill 2 adt
              cts  = getADTCts adt'
              cses = map (\ (cnam, cbod) ->
                if cnam == "_" then
                  (cnam, ["_"], t2ct cbod Nothing dep)
                else case lookup cnam cts of
                  Just (Ctr _ tele) ->
                    let fNames = getTeleNames tele dep []
                    in (cnam, fNames, t2ct cbod Nothing dep)
                  Nothing -> error $ "constructor-not-found:" ++ cnam) cse
          in CLam "x" $ \x -> CMat x cses
        otherwise -> error "match-without-type"
    go (All _ _ _) =
      CNul
    go (Ref nam) =
      CRef nam
    go (Let nam val bod) =
      let val' = t2ct val Nothing dep
          bod' = \x -> t2ct (bod (Var nam dep)) Nothing (dep+1)
      in CLet nam val' bod'
    go (Use nam val bod) =
      t2ct (bod val) typx dep
    go Set =
      CNul
    go U64 =
      CNul
    go F64 =
      CNul
    go (Num val) =
      CNum val
    go (Flt val) =
      CFlt val
    go (Op2 opr fst snd) =
      let fst' = t2ct fst Nothing dep
          snd' = t2ct snd Nothing dep
      in COp2 opr fst' snd'
    go (Swi zer suc) =
      let zer' = t2ct zer Nothing dep
          suc' = t2ct suc Nothing dep
      in CSwi zer' suc'
    go (Txt txt) =
      CTxt txt
    go (Lst lst) =
      CLst (map (\x -> t2ct x Nothing dep) lst)
    go (Nat val) =
      CNat val
    go (Hol _ _) =
      CNul
    go (Met _ _) =
      CNul
    go (Log msg nxt) =
      let msg' = t2ct msg Nothing dep
          nxt' = t2ct nxt Nothing dep
      in CLog msg' nxt'
    go (Var nam idx) =
      CVar nam idx
    go (Src _ val) =
      t2ct val typx dep

-- Converts a term to a top-level Function.
-- - Returns the arity and whether it is tail recursive.
-- - Lifts shareable lambdas across branches:
--     from λx match v { #Foo{a b}: (λy λz A) #Bar: (λy λz B) ... }
--       to λx λy λz match v { #Foo{a b}: A #Bar: B ... }
ctToFn :: String -> [String] -> CT -> FN
ctToFn func args ct =
  let (arity, body) = pull ct 0 0 0
  in {-trace ("RET ARITY = " ++ show arity ++ " ARGS = " ++ show [var i | i <- [0..arity-1]]) $-}
     FN [var i | i <- [0..arity-1]] (bindCT body [])
  where

  -- if the int is in args, return it. otherwise, return "v" ++ show i
  var :: Int -> String
  var i | i < length args = args !! i ++ show i
  var i | otherwise       = "v"       ++ show i

  pull :: CT -> Int -> Int -> Int -> (Int, CT)
  pull ct dep ari skp =
    -- trace ("pull " ++ showCT ct ++ " ### dep=" ++ show dep ++ " ari=" ++ show ari ++ " skp=" ++ show skp) $
    go ct dep ari skp where

    go (CLam nam bod) dep ari 0 =
      let (ari', bod') = pull (bod (CVar (var ari) dep)) (dep+1) (ari+1) 0
      in (ari', bod')
    go (CLam nam bod) dep ari skp =
      let (ari', bod') = pull (bod (CVar nam dep)) (dep+1) ari (skp-1)
      in (ari', CLam nam (\x -> bod'))
    go app@(CApp _ _) dep ari skp =
      let (fun, args) = getAppChain app
      in case fun of
        CRef nm ->
          if nm == func && length args == ari
            then (ari, app)
            else (0, app)
        otherwise ->
          (0, app)
    go (CMat val cse) dep ari skp | length cse > 0 =
      let rec   = flip map cse $ \ (cnam, cfds, cbod) -> pull cbod dep ari (skp + length cfds)
          aris  = map (\(a,_) -> a) rec
          cnams = flip map cse $ \ (n,_,_) -> n
          cflds = flip map cse $ \ (_,f,_) -> f
          cbods = flip map rec $ \ (_,b)   -> b
          warn  = if all (== head aris) aris
            then id
            else trace ("WARNING: inconsistent cross-branch lambda count on: " ++ showCT ct)
      in warn (head aris, CMat val (zip3 cnams cflds cbods))
    go (CLet nam val bod) dep ari skp =
      let (ari', bod') = pull (bod (CVar nam dep)) (dep+1) ari skp
      in (ari', CLet nam val (\x -> bod'))
    go term dep ari s =
      (ari, term)

-- JavaScript Codegen
-- ------------------

-- Converts a compilable term into JavaScript source
fnToJS :: Book -> Fill -> ArityMap -> String -> FN -> ST.State Int String
fnToJS book fill aMap func (FN args term) = do
  bodyName <- fresh
  bodyStmt <- ctToJS True (Just bodyName) term 0
  
  -- TODO: must wrap ct with lambdas, one per argument, and assign to a global const. ex:
  -- const <func-name> = arg0 => arg1 => arg2 => .. => { <bodyStmt> return bodyName }
  let body = concat ["{ while (1) { ", bodyStmt, "return ", bodyName, "; } }"]
  let expr = if null args
        then concat ["(() => ", body, ")()"]
        else concat [intercalate " => " args, " => ", body]
  return $ concat ["const ", nameToJS func, " = ", expr]

  where

  -- Assigns an expression to a name, or return it directly
  ret :: Maybe String -> String -> ST.State Int String
  ret (Just name) expr = return $ "var " ++ name ++ " = " ++ expr ++ ";"
  ret Nothing     expr = return $ expr

  -- TODO: convert to (func', args') using getAppChain. then, check if func is (Ref nm) with nm == func, and length args == length args'
  -- FIXME: we must also track if we're in a tail position
  isRecCall :: CT -> Bool
  isRecCall app =
    let (func', args') = getAppChain app
    in case func' of
      CRef fNam ->
        let isSameFunc  = fNam == func
            isSameArity = length args' == length args
        in isSameFunc && isSameArity
      _ -> False

  ctToJS tail var term dep = go term where
    go CNul =
      ret var "null"
    go tm@(CLam nam bod) = do
      let (names, bodyTerm, _) = lams tm dep []
      bodyName <- fresh
      bodyStmt <- ctToJS False (Just bodyName) bodyTerm (dep + length names)
      ret var $ concat ["(", intercalate " => " names, " => {", bodyStmt, "return ", bodyName, ";})"]
      where
        lams :: CT -> Int -> [String] -> ([String], CT, Maybe Term)
        lams (CLam n b) dep names =
          let uid = nameToJS n ++ "$" ++ show dep
          in lams (b (CVar uid dep)) (dep + 1) (uid : names)
        lams term       dep names = (reverse names, term, Nothing)
    go app@(CApp fun arg) | tail && isRecCall app = do
      -- TODO: here, we will mutably set the function's arguments with the new argList values, and 'continue'
      -- TODO: AI generated, review
      let (func', argTerms) = getAppChain app
      argDefs <- forM (zip args argTerms) $ \(paramName, argTerm) -> do
        argName <- fresh
        argStmt <- ctToJS False (Just argName) argTerm dep
        return (argStmt, paramName ++ " = " ++ argName ++ ";")
      let (argStmts, paramDefs) = unzip argDefs
      return $ concat argStmts ++ concat paramDefs ++ " continue;"
    go (CApp fun@(CLam nam bod) arg) = do
      ctToJS tail var (bod arg) dep
    go (CApp fun arg) = do
      funExpr <- ctToJS False Nothing fun dep
      argExpr <- ctToJS False Nothing arg dep
      ret var $ concat ["(", funExpr, ")(", argExpr, ")"]
    go (CCon nam fields) = do
      fieldExprs <- forM fields $ \ (fname, fterm) -> do
        expr <- ctToJS False Nothing fterm dep
        return (fname, expr)
      let fields' = concatMap (\ (fname, expr) -> ", " ++ fname ++ ": " ++ expr) fieldExprs
      ret var $ concat ["({$: \"", nam, "\"", fields', "})"]
    go (CMat val cses) = do
      valName <- fresh
      valStmt <- ctToJS False (Just valName) val dep
      retName <- case var of
        Just var -> return var
        Nothing  -> fresh
      cases <- forM cses $ \ (cnam, fields, cbod) ->
        if cnam == "_" then do
          retStmt <- ctToJS tail (Just retName) (CApp cbod (CVar valName 0)) dep
          return $ concat ["default: { " ++ retStmt, " break; }"]
        else do
          let bod = foldl CApp cbod (map (\f -> (CVar (valName++"."++f) 0)) fields)
          retStmt <- ctToJS tail (Just retName) bod dep
          return $ concat ["case \"", cnam, "\": { ", retStmt, " break; }"]
      let switch = concat [valStmt, "switch (", valName, ".$) { ", unwords cases, " }"]
      case var of
        Just var -> return $ switch
        Nothing  -> ret var $ concat ["(()=>{", switch, "})()"]
    go (CRef nam) =
      ret var $ nameToJS nam
    go (CLet nam val bod) =
      case var of
        Just var -> do
          let uid = nameToJS nam ++ "$" ++ show dep
          valExpr <- ctToJS False (Just uid) val dep
          bodExpr <- ctToJS tail (Just var) (bod (CVar uid dep)) (dep + 1)
          return $ concat [valExpr, bodExpr]
        Nothing -> do
          let uid = nameToJS nam ++ "$" ++ show dep
          valExpr <- ctToJS False (Just uid) val dep
          bodExpr <- ctToJS tail Nothing (bod (CVar uid dep)) (dep + 1)
          return $ concat ["(() => {", valExpr, "return ", bodExpr, ";})()"]
    go (CNum val) =
      ret var $ show val
    go (CFlt val) =
      ret var $ show val
    go (COp2 opr fst snd) = do
      let opr' = operToJS opr
      fstExpr <- ctToJS False Nothing fst dep
      sndExpr <- ctToJS False Nothing snd dep
      ret var $ concat ["((", fstExpr, " ", opr', " ", sndExpr, ") >>> 0)"]
    -- FIXME: must transform like we did with Mat. this is currently wrong
    go (CSwi zer suc) = do
      zerExpr <- ctToJS tail Nothing zer dep
      sucExpr <- ctToJS tail Nothing suc dep
      ret var $ concat ["((x => x === 0 ? ", zerExpr, " : ", sucExpr, "(x - 1)))"]
    go (CLog msg nxt) = do
      msgExpr <- ctToJS False Nothing msg dep
      nxtExpr <- ctToJS tail Nothing nxt dep
      ret var $ concat ["(console.log(LIST_TO_JSTR(", msgExpr, ")), ", nxtExpr, ")"]
    go (CVar nam _) =
      ret var nam
    go (CTxt txt) =
      ret var $ "JSTR_TO_LIST(`" ++ txt ++ "`)"
    go (CLst lst) =
      let cons = \x acc -> CCon "Cons" [("head", x), ("tail", acc)]
          nil  = CCon "Nil" []
      in  ctToJS False var (foldr cons nil lst) dep
    go (CNat val) =
      let succ = \x -> CCon "Succ" [("pred", x)]
          zero = CCon "Zero" []
      in  ctToJS False var (foldr (\_ acc -> succ acc) zero [1..val]) dep

operToJS :: Oper -> String
operToJS ADD = "+"
operToJS SUB = "-"
operToJS MUL = "*"
operToJS DIV = "/"
operToJS MOD = "%"
operToJS EQ  = "==="
operToJS NE  = "!=="
operToJS LT  = "<"
operToJS GT  = ">"
operToJS LTE = "<="
operToJS GTE = ">="
operToJS AND = "&"
operToJS OR  = "|"
operToJS XOR = "^"
operToJS LSH = "<<"
operToJS RSH = ">>"

nameToJS :: String -> String
nameToJS x = "$" ++ map (\c -> if c == '/' || c == '.' || c == '-' || c == '#' then '$' else c) x

fresh :: ST.State Int String
fresh = do
  n <- ST.get
  ST.put (n + 1)
  return $ "$x" ++ show n

prelude :: String
prelude = unlines [
  "function LIST_TO_JSTR(list) {",
  "  try {",
  "    let result = '';",
  "    let current = list;",
  "    while (current.$ === 'Cons') {",
  "      result += String.fromCodePoint(current.head);",
  "      current = current.tail;",
  "    }",
  "    if (current.$ === 'Nil') {",
  "      return result;",
  "    }",
  "  } catch (e) {}",
  "  return list;",
  "}",
  "",
  "function JSTR_TO_LIST(str) {",
  "  let list = {$: 'Nil'};",
  "  for (let i = str.length - 1; i >= 0; i--) {",
  "    list = {$: 'Cons', head: str.charCodeAt(i), tail: list};",
  "  }",
  "  return list;",
  "}"
  ]

genCmp :: Book -> (String, Term) -> (String, Book, Fill, FN)
genCmp book (name, term) =
  case envRun (doAnnotate term) book of
    Done _ (term, fill) ->
      let ct = termToCT book fill (bind term []) Nothing 0
          fn = ctToFn name (getArgNames (bind term [])) ct
      in (name, book, fill, fn)
    Fail _ ->
      error $ "COMPILATION_ERROR: " ++ name ++ " isn't well-typed."

genArityMap :: [(String, Book, Fill, FN)] -> M.Map String Int
genArityMap cmps = M.fromList [(name, fnArity fn) | (name, _, _, fn) <- cmps]

cmpToJS :: ArityMap -> (String, Book, Fill, FN) -> String
cmpToJS aMap (name, book, fill, fn@(FN arity ct)) = ST.evalState (fnToJS book fill aMap name (FN arity ct)) 0 ++ "\n\n"

compileJS :: Book -> String
compileJS book =
  let sortedBook = topoSortBook book
      sortedCmps = map (genCmp book) sortedBook
      arityMap   = genArityMap sortedCmps
      sortedFuns = concatMap (cmpToJS arityMap) sortedCmps
  in prelude ++ "\n\n" ++ sortedFuns

-- Utils
-- -----

bindCT :: CT -> [(String,CT)] -> CT
bindCT CNul ctx = CNul
bindCT (CLam nam bod) ctx =
  let bod' = \x -> bindCT (bod (CVar nam 0)) ((nam, x) : ctx) in
  CLam nam bod'
bindCT (CApp fun arg) ctx =
  let fun' = bindCT fun ctx in
  let arg' = bindCT arg ctx in
  CApp fun' arg'
bindCT (CCon nam arg) ctx =
  let arg' = map (\(f, x) -> (f, bindCT x ctx)) arg in
  CCon nam arg'
bindCT (CMat val cse) ctx =
  let val' = bindCT val ctx in
  let cse' = map (\(cn,fs,cb) -> (cn, fs, bindCT cb ctx)) cse in
  CMat val' cse'
bindCT (CRef nam) ctx =
  case lookup nam ctx of
    Just x  -> x
    Nothing -> CRef nam
bindCT (CLet nam val bod) ctx =
  let val' = bindCT val ctx in
  let bod' = \x -> bindCT (bod (CVar nam 0)) ((nam, x) : ctx) in
  CLet nam val' bod'
bindCT (CNum val) ctx = CNum val
bindCT (CFlt val) ctx = CFlt val
bindCT (COp2 opr fst snd) ctx =
  let fst' = bindCT fst ctx in
  let snd' = bindCT snd ctx in
  COp2 opr fst' snd'
bindCT (CSwi zer suc) ctx =
  let zer' = bindCT zer ctx in
  let suc' = bindCT suc ctx in
  CSwi zer' suc'
bindCT (CLog msg nxt) ctx =
  let msg' = bindCT msg ctx in
  let nxt' = bindCT nxt ctx in
  CLog msg' nxt'
bindCT (CVar nam idx) ctx =
  case lookup nam ctx of
    Just x  -> x
    Nothing -> CVar nam idx
bindCT (CTxt txt) ctx = CTxt txt
bindCT (CLst lst) ctx =
  let lst' = map (\x -> bindCT x ctx) lst in
  CLst lst'
bindCT (CNat val) ctx = CNat val

fnArity :: FN -> Int
fnArity (FN args _) = length args

fnCT :: FN -> CT
fnCT (FN _ ct) = ct

-- Stringification
-- ---------------

-- TODO: implement a showCT :: CT -> String function
showCT :: CT -> String
showCT CNul               = "*"
showCT (CLam nam bod)     = "λ" ++ nam ++ " " ++ showCT (bod (CVar nam 0))
showCT (CApp fun arg)     = "(" ++ showCT fun ++ " " ++ showCT arg ++ ")"
showCT (CCon nam fields)  = "#" ++ nam ++ "{" ++ concatMap (\(f,t) -> f ++ ":" ++ showCT t ++ " ") fields ++ "}"
showCT (CMat val cses)    = "match " ++ showCT val ++ " {" ++ concatMap (\(cn,fs,cb) -> "#" ++ cn ++ ":" ++ showCT cb ++ " ") cses ++ "}"
showCT (CRef nam)         = nam
showCT (CLet nam val bod) = "let " ++ nam ++ " = " ++ showCT val ++ "; " ++ showCT (bod (CVar nam 0))
showCT (CNum val)         = show val
showCT (CFlt val)         = show val
showCT (COp2 opr fst snd) = "(<op> " ++ showCT fst ++ " " ++ showCT snd ++ ")"
showCT (CSwi zer suc)     = "switch(" ++ showCT zer ++ "," ++ showCT suc ++ ")"
showCT (CLog msg nxt)     = "log(" ++ showCT msg ++ "," ++ showCT nxt ++ ")"
showCT (CVar nam _)       = nam
showCT (CTxt txt)         = show txt
showCT (CLst lst)         = "[" ++ unwords (map showCT lst) ++ "]"
showCT (CNat val)         = show val

-- Utils
-- -----

getAppChain :: CT -> (CT, [CT])
getAppChain (CApp fun arg) =
  let (f, args) = getAppChain fun
  in (f, args ++ [arg])
getAppChain term = (term, [])

-- Tests
-- -----

-- data A = #Foo{x0 x1} | #Bar
-- data B = #T | #F

-- test0 = λx match x {
--   #Foo: λx0 λx1 λy match y {
--     #Foo: λy0 λy1 λz λw 10
--     #Bar: λz λw 20
--   }
--   #Bar: λy match y {
--     #Foo: λy0 λy1 λz λw 30
--     #Bar: λz λw 40
--   }
-- }
test0 :: CT
test0 = CLam "x" $ \x -> CMat x [
    ("Foo", ["x0", "x1"], CLam "x0" $ \x0 -> CLam "x1" $ \x1 -> CLam "y" $ \y -> CMat y [
      ("Foo", ["y0", "y1"], CLam "y0" $ \y0 -> CLam "y1" $ \y1 -> CLam "z" $ \z -> CLam "w" $ \w -> CNum 10),
      ("Bar", [], CLam "z" $ \z -> CLam "w" $ \w -> CNum 20)
    ]),
    ("Bar", [], CLam "y" $ \y -> CMat y [
      ("Foo", ["y0", "y1"], CLam "y0" $ \y0 -> CLam "y1" $ \y1 -> CLam "z" $ \z -> CLam "w" $ \w -> CNum 30),
      ("Bar", [], CLam "z" $ \z -> CLam "w" $ \w -> CNum 40)
    ])
  ]

-- test1 = λx match x {
--   #Foo: λx0 match x0 {
--     #T: λx1 λy match y {
--       #Foo: λy0 λy1 λz λw 10
--       #Bar: λz λw 20
--     }
--     #F: λx1 λy λz λw 15
--   }
--   #Bar: λy match y {
--     #Foo: λy0 λy1 λz λw 30
--     #Bar: λz λw 40
--   }
-- }
test1 :: CT
test1 = CLam "x" $ \x -> CMat x [
    ("Foo", ["x0"], CLam "x0" $ \x0 -> CMat x0 [
      ("T", ["x1"], CLam "x1" $ \x1 -> CLam "y" $ \y -> CMat y [
        ("Foo", ["y0", "y1"], CLam "y0" $ \y0 -> CLam "y1" $ \y1 -> CLam "z" $ \z -> CLam "w" $ \w -> CNum 10),
        ("Bar", [], CLam "z" $ \z -> CLam "w" $ \w -> CNum 20)
      ]),
      ("F", ["x1"], CLam "x1" $ \x1 -> CLam "y" $ \y -> CLam "z" $ \z -> CLam "w" $ \w -> CNum 15)
    ]),
    ("Bar", [], CLam "y" $ \y -> CMat y [
      ("Foo", ["y0", "y1"], CLam "y0" $ \y0 -> CLam "y1" $ \y1 -> CLam "z" $ \z -> CLam "w" $ \w -> CNum 30),
      ("Bar", [], CLam "z" $ \z -> CLam "w" $ \w -> CNum 40)
    ])
  ]

ctest :: IO ()
ctest = do
  putStrLn $ showCT test1
  putStrLn $ showCT $ fnCT (ctToFn "foo" [] test1)

























