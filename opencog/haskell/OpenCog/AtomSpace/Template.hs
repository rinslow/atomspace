-- GSoC 2015 - Haskell bindings for OpenCog.
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell    #-}

-- | This Module defines the main util functions to use Template Haskell
-- in order to reduce as much boilerplate code as possible.
module OpenCog.AtomSpace.Template (
  declareAtomType
, declareAtomFilters
, atomHierarchyFile
) where

import Language.Haskell.TH.Quote        (QuasiQuoter(..),dataToExpQ,quoteFile)
import Language.Haskell.TH
import Data.List                        (isSuffixOf,sortBy,(\\),groupBy)
import Data.Char                        (toUpper,toLower)
import Data.Data                        (Data,Typeable)
import Data.Map.Strict                  (Map,mapKeys,toList,fromList,insert,
                                         empty,(!),keys,member)
import qualified Data.Map.Strict as M   (map)
import Control.Monad.State              (State,modify,get,execState)

-- | Simple Atom representation.
data AT = NOD String
        | LNK String
    deriving (Typeable,Data,Eq,Ord,Show)

-- | Template function to define AtomType and some util functions over it.
declareAtomType :: [(AT,[AT])] -> Q [Dec]
declareAtomType atomMap = do
    a <- newName "a"
    let
      atomType      = mkName "AtomType"
      functionName1 = mkName "toAtomTypeRaw"
      functionName2 = mkName "fromAtomTypeRaw"
      typeFamName1  = mkName "Up"
      typeFamName2  = mkName "Down"
      constrNames   = map (\(nod,parents) ->
                                (mkName (toTypeName nod)
                                ,toRawName nod
                                ,map (mkName . toTypeName) parents)) atomMap
      revTree       = reverseTree atomMap
      constrNamesRev= map (\(nod,children) ->
                                (mkName (toTypeName nod)
                                ,map (mkName . toTypeName) children)) revTree
      constr      = map (\(x,_,_) -> NormalC x []) constrNames
      typeDef     = DataD [] atomType [] constr [''Eq, ''Show, ''Typeable, ''Read]
      funDef1     = FunD functionName1 (map createClause1 constrNames)
      funDef2     = FunD functionName2 (map createClause2 constrNames)
      typeFamDef1 = ClosedTypeFamilyD typeFamName1 [PlainTV a]
                    (Just (AppT ListT (ConT atomType)))
                    (map createClause3 constrNames)
      typeFamDef2 = ClosedTypeFamilyD typeFamName2 [PlainTV a]
                    (Just (AppT ListT (ConT atomType)))
                    (map createClause4 constrNamesRev)

      createClause1 (n,s,_)  = Clause [ConP n []]
                                 (NormalB (LitE (StringL s)))
                                 []

      createClause2 (n,s,_)  = Clause [LitP (StringL s)]
                                 (NormalB (AppE (ConE $ mkName "Just") (ConE n)))
                                 []

      createClause3 (n,_,p)  = TySynEqn [PromotedT n] (genlist p)

      createClause4 (n,p)    = TySynEqn [PromotedT n] (genlist p)

     in return [typeDef,funDef1,funDef2,typeFamDef1,typeFamDef2]
  where
    genlist []     = PromotedNilT
    genlist (x:xs) = AppT (AppT PromotedConsT (PromotedT x)) (genlist xs)

-- | Template function to declare Filter instances for each AtomType.
declareAtomFilters :: [(AT,[AT])] -> Q [Dec]
declareAtomFilters atomMap = do
    let
      className     = mkName "FilterIsChild"
      classFnName   = mkName "filtIsChild"
      constrNames   = map (mkName . toTypeName . fst) atomMap
      classDef      = map createInstance constrNames

      createInstance n = InstanceD []
          (AppT (ConT className) (PromotedT n))
          [ValD (VarP classFnName) (NormalB (AppE (VarE $ mkName "filtChild")
            (SigE
              (ConE $ mkName "Proxy")
              (AppT (ConT $ mkName "Proxy")
                    (AppT (ConT $ mkName "Children")
                          (PromotedT n)))))) []
          ]
     in return classDef

-- | QuasiQuorter to read the atom_types.script file.
atomHierarchyFile :: QuasiQuoter
atomHierarchyFile = quoteFile atomHierarchy

atomHierarchy :: QuasiQuoter
atomHierarchy = QuasiQuoter {
      quoteExp  = dataToExpQ (\x -> Nothing) . parser
    , quotePat  = undefined
    , quoteDec  = undefined
    , quoteType = undefined
    }

type NameMap = Map String String
type AtomMap = Map String [String]
type PState = State (NameMap,AtomMap)

onNameMap :: (NameMap -> NameMap) -> PState ()
onNameMap f = modify (\(s1,s2) -> (f s1,s2))

onAtomMap :: (AtomMap -> AtomMap) -> PState ()
onAtomMap f = modify (\(s1,s2) -> (s1,f s2))

-- | 'parser' reads the text of the atom_types.script file and generate a list
-- of tuples (Atom, Parent of that Atom).
parser :: String -> [(AT,[AT])]
parser s = ( toList
           . M.map (map toAT)
           . mapKeys toAT
           . snd
           ) $ execState (withState s) (empty,empty)
  where
    withState :: String -> PState ()
    withState s = do
          onLines s
          mapToCamelCase
    onLines :: String -> PState ()
    onLines = mapM_ parseLine
            . map removeComm
            . lines
    mapToCamelCase :: PState ()
    mapToCamelCase = do
        (nameMap,_) <- get
        onAtomMap $ M.map $ map $ format nameMap
        onAtomMap $ mapKeys $ format nameMap
    format :: NameMap -> String -> String
    format dict s = if member s dict
                      then dict!s
                      else toCamelCase s

removeComm :: String -> String
removeComm ('/':'/':_) = []
removeComm (x:xs) = x : removeComm xs
removeComm [] = []

parseLine :: String -> PState ()
parseLine s = case words (map repl s) of
    aname:[]          -> onAtomMap $ insert aname []
    aname:"<-":(x:xs) -> case lookReName (x:xs) of
        Nothing   -> onAtomMap $ insert aname (x:xs)
        Just name -> do
            onNameMap $ insert aname name
            onAtomMap $ insert aname $ init (x:xs)
    _                 -> return ()
  where
    repl ',' = ' '
    repl  x  = x
    lookReName [] = Nothing
    lookReName xs = case (last xs,last $ last xs) of
        ('"':y:ys,'"') -> Just $ init (y:ys)
        _              -> Nothing

toCamelCase :: String -> String
toCamelCase = concat
            . map capital
            . words
            . map repl
  where
      repl '_' = ' '
      repl  x  = x
      capital (x:xs) = toUpper x : map toLower xs
      capital []     = []

toAT :: String -> AT
toAT "Notype" = NOD "Notype"
toAT "Atom"   = NOD "Atom"
toAT "Node"   = NOD "Node"
toAT "Link"   = LNK "Link"
toAT xs | isSuffixOf "Node" xs = NOD xs
        | otherwise = LNK xs

toTypeName :: AT -> String
toTypeName (NOD "Node") = "NodeT"
toTypeName (NOD s) = if isSuffixOf "Node" s
                        then take (length s - 4) s ++ "T"
                        else s ++ "T"
toTypeName (LNK "Link") = "LinkT"
toTypeName (LNK s) = if isSuffixOf "Link" s
                        then take (length s - 4) s ++ "T"
                        else s ++ "T"

toRawName :: AT -> String
toRawName (NOD n) = n
toRawName (LNK l) = l

-- | 'reverseTree' reverses the information provided in the atom_types.script file.
-- From input: [(Atom, parent of Atom)]
-- It gets as output: [(Atom, children of Atom)]
reverseTree :: [(AT,[AT])] -> [(AT,[AT])]
reverseTree t = let rt = reverseTree' t
                 in rt ++ map (\x -> (x,[])) (map fst t \\ map fst rt)

reverseTree' :: [(AT,[AT])] -> [(AT,[AT])]
reverseTree' = concat
             . map aux2
             . groupBy (\x y -> fst x == fst y)
             . sortBy (\a b -> compare (fst a) (fst b))
             . concat
             . map aux
  where
    aux :: (AT,[AT]) -> [(AT,AT)]
    aux (x,xs) = map (\y -> (y,x)) xs
    aux2 :: [(AT,AT)] -> [(AT,[AT])]
    aux2 []         = []
    aux2 ((x,y):ys) = [(x,y : map snd ys)]

