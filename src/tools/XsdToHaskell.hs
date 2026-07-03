-- XsdToHaskell
module Main where

-- This program is designed to convert an XML file containing an XSD
-- decl into a Haskell module containing data/newtype definitions which
-- mirror the XSD.  Once you have used this program to generate your type
-- definitions, you should import Xsd2Haskell wherever you intend
-- to read and write XML files with your Haskell programs.

import System.Environment
import System.Exit
import System.IO
import System.Directory
import Control.Monad
import Data.Maybe (mapMaybe)
--import Data.Either

--import Text.XML.HaXml.Wrappers   (fix2Args)
import Text.XML.HaXml            (version)
import Text.XML.HaXml.Types
import Text.XML.HaXml.Namespaces (resolveAllNames,qualify
                                 ,nullNamespace)
import Text.XML.HaXml.Parse      (xmlParse')
import Text.XML.HaXml.Util       (docContent)
import Text.XML.HaXml.Posn       (posInNewCxt)

import Text.XML.HaXml.Schema.Parse
import Text.XML.HaXml.Schema.Environment
import Text.XML.HaXml.Schema.NameConversion
import Text.XML.HaXml.Schema.TypeConversion
import Text.XML.HaXml.Schema.XSDTypeModel (Schema)
import Text.XML.HaXml.Schema.PrettyHaskell
import qualified Text.XML.HaXml.Schema.PrettyHsBoot as HsBoot
import qualified Text.XML.HaXml.Schema.HaskellTypeModel as Haskell
import Text.ParserCombinators.Poly
import Text.PrettyPrint.HughesPJ (render)

-- sucked in from Text.XML.HaXml.Wrappers to avoid dependency on T.X.H.Html
fix2Args :: IO (String,String)
fix2Args = do
  args <- getArgs
  when ("--version" `elem` args) $ do
      putStrLn $ "part of HaXml-"++version
      exitSuccess
  when ("--help" `elem` args) $ do
      putStrLn "See http://haskell.org/HaXml"
      exitSuccess
  case length args of
    0 -> return ("-",     "-")
    1 -> return (args!!0, "-")
    2 -> return (args!!0, args!!1)
    _ -> do prog <- getProgName
            putStrLn ("Usage: "++prog++" [xmlfile] [outfile]")
            exitFailure


main ::IO ()
main =
  fix2Args >>= \(inf,outf)->
  ( if inf=="-" then getContents
    else readFile inf )           >>= \thiscontent->
  ( if outf=="-" then return stdout
    else openFile outf WriteMode ) >>= \o->
  let d@Document{} = resolveAllNames qualify
                     . either (error . ("not XML:\n"++)) id
                     . xmlParse' inf
                     $ thiscontent
  in do
    case runParser schema [docContent (posInNewCxt inf Nothing) d] of
        (Left msg,_) -> do hPutStrLn stderr msg
                           exitFailure
        (Right v,[]) -> do putStrLn "Parse Success!"
                           putStrLn "\n-----------------\n"
                           putStrLn $ show v
                           putStrLn "\n-----------------\n"
                           env <- schemaEnvironment inf v
                           sourceMods <- sourceImportModules inf v
                           let decls = markSourceImports sourceMods (convert env v)
                               haskl = Haskell.mkModule inf v decls
                               doc   = ppModule simpleNameConverter haskl
                           hPutStrLn o $ render doc
                           when (outf /= "-") $ do
                             bootNeeded <- needsBootFile inf v
                             let bootPath = bootf outf
                             if bootNeeded
                               then writeFile bootPath
                                      (render (HsBoot.ppModule simpleNameConverter haskl) ++ "\n")
                               else do
                                 bootExists <- doesFileExist bootPath
                                 when bootExists (removeFile bootPath)
        (Right v,_)  -> do putStrLn "Parse incomplete!"
                           putStrLn "\n-----------------\n"
                           putStrLn $ show v
                           putStrLn "\n-----------------\n"
                           exitFailure
    hFlush o

schemaEnvironment :: FilePath -> Schema -> IO Environment
schemaEnvironment "-" v = return (mkEnvironment "-" v emptyEnv)
schemaEnvironment inf v = do
    canon <- canonicalizePath inf
    env <- dependencyEnvironment [canon] canon v
    return (mkEnvironment inf v env)

dependencyEnvironment :: [FilePath] -> FilePath -> Schema -> IO Environment
dependencyEnvironment seen base v = do
    envs <- mapM (loadDependency seen base . fst) (gatherImports v)
    return (foldr combineEnv emptyEnv envs)

loadDependency :: [FilePath] -> FilePath -> FilePath -> IO Environment
loadDependency seen base loc = do
    let path = resolveSchemaLocation base loc
    exists <- doesFileExist path
    if not exists
      then return emptyEnv
      else do
        canon <- canonicalizePath path
        if canon `elem` seen
          then return emptyEnv
          else do
            mv <- parseSchemaFile canon
            case mv of
              Nothing -> return emptyEnv
              Just v  -> do
                env <- dependencyEnvironment (canon:seen) canon v
                return (mkEnvironment canon v env)

sourceImportModules :: FilePath -> Schema -> IO [XName]
sourceImportModules "-" _ = return []
sourceImportModules inf v = do
    canon <- canonicalizePath inf
    fmap concat $ forM (gatherImports v) $ \(loc,_) -> do
      let path = resolveSchemaLocation canon loc
      exists <- doesFileExist path
      if not exists
        then return []
        else do
          dep <- canonicalizePath path
          mv <- parseSchemaFile dep
          case mv of
              Nothing -> return []
              Just dv -> do
                reaches <- importsReach [canon,dep] dep dv canon
                return [xname loc | reaches && sourceImportEdge canon dep]

needsBootFile :: FilePath -> Schema -> IO Bool
needsBootFile "-" _ = return False
needsBootFile inf v = do
    target <- canonicalizePath inf
    bootRequiredByReachableModule [target] target target v

bootRequiredByReachableModule :: [FilePath] -> FilePath -> FilePath -> Schema
                              -> IO Bool
bootRequiredByReachableModule seen target base v = do
    neededHere <- moduleSourceImportsFile target base v
    if neededHere
      then return True
      else anyM checkDependency (gatherImports v)
  where
    checkDependency (loc,_) = do
      let path = resolveSchemaLocation base loc
      exists <- doesFileExist path
      if not exists
        then return False
        else do
          dep <- canonicalizePath path
          if dep `elem` seen
            then return False
            else do
              mv <- parseSchemaFile dep
              case mv of
                Nothing -> return False
                Just dv -> bootRequiredByReachableModule (dep:seen) target dep dv

moduleSourceImportsFile :: FilePath -> FilePath -> Schema -> IO Bool
moduleSourceImportsFile target base v = do
    env <- schemaEnvironment base v
    sourceMods <- sourceImportModules base v
    let decls = markSourceImports sourceMods (convert env v)
        haskl = Haskell.mkModule base v decls
    paths <- sourceImportFilePaths base haskl
    return (any (== target) (filter (/= base) paths))

sourceImportFilePaths :: FilePath -> Haskell.Module -> IO [FilePath]
sourceImportFilePaths base haskl =
    fmap concat $ forM (sourceImportModulesOf haskl) $ \modName ->
      case xnameFilePath modName of
        Nothing -> return []
        Just loc -> do
          let path = resolveSchemaLocation base loc
          exists <- doesFileExist path
          if not exists
            then return []
            else do
              canon <- canonicalizePath path
              return [canon]

sourceImportModulesOf :: Haskell.Module -> [XName]
sourceImportModulesOf haskl =
    concatMap sourceImportDecl
              (Haskell.module_re_exports haskl
               ++ Haskell.module_import_only haskl
               ++ Haskell.module_decls haskl)
  where
    sourceImportDecl (Haskell.XSDIncludeSource m _) = [m]
    sourceImportDecl (Haskell.XSDImportSource m _ _) = [m]
    sourceImportDecl (Haskell.ElementsAttrsAbstract _ deps _) =
        mapMaybe snd deps
    sourceImportDecl (Haskell.ExtendComplexTypeAbstract _ _ deps _ _ _) =
        mapMaybe snd deps
    sourceImportDecl (Haskell.ElementAbstractOfType _ _ deps _) =
        mapMaybe snd deps
    sourceImportDecl _ = []

xnameFilePath :: XName -> Maybe FilePath
xnameFilePath (XName (N path)) = Just path
xnameFilePath (XName (QN _ path)) = Just path

importsReach :: [FilePath] -> FilePath -> Schema -> FilePath -> IO Bool
importsReach seen base v target =
    anyM reachesImport (gatherImports v)
  where
    reachesImport (loc,_) = do
      let path = resolveSchemaLocation base loc
      exists <- doesFileExist path
      if not exists
        then return False
        else do
          dep <- canonicalizePath path
          if dep == target
            then return True
            else if dep `elem` seen
              then return False
              else do
                mv <- parseSchemaFile dep
                case mv of
                  Nothing -> return False
                  Just dv -> importsReach (dep:seen) dep dv target

anyM :: Monad m => (a -> m Bool) -> [a] -> m Bool
anyM _ [] = return False
anyM p (x:xs) = do
    found <- p x
    if found then return True else anyM p xs

markSourceImports :: [XName] -> [Haskell.Decl] -> [Haskell.Decl]
markSourceImports sourceMods = map mark
  where
    mark (Haskell.XSDInclude m comm)
      | m `elem` sourceMods = Haskell.XSDIncludeSource m comm
    mark (Haskell.XSDImport m ma comm)
      | m `elem` sourceMods = Haskell.XSDImportSource m ma comm
    mark d = d

moduleKey :: FilePath -> String
moduleKey = reverse . takeWhile (/='/') . reverse

sourceImportEdge :: FilePath -> FilePath -> Bool
sourceImportEdge importer imported = moduleKey importer > moduleKey imported

parseSchemaFile :: FilePath -> IO (Maybe Schema)
parseSchemaFile inf = do
    thiscontent <- readFile inf
    let d@Document{} = resolveAllNames qualify
                       . either (error . ("not XML:\n"++)) id
                       . xmlParse' inf
                       $ thiscontent
    case runParser schema [docContent (posInNewCxt inf Nothing) d] of
      (Left msg,_) -> do hPutStrLn stderr (inf++": "++msg)
                         return Nothing
      (Right v,_)  -> return (Just v)

resolveSchemaLocation :: FilePath -> FilePath -> FilePath
resolveSchemaLocation base loc
    | absolute loc = loc
    | otherwise    = let dir = directory base
                     in if null dir then loc else dir++"/"++loc
  where
    absolute ('/':_) = True
    absolute _       = False
    directory path = case dropWhile (/='/') (reverse path) of
                       []       -> ""
                       (_:rest) -> reverse rest

-- | Munge filename for hs-boot.
bootf :: FilePath -> FilePath
bootf x = case reverse x of
            's':'h':'.':f -> reverse f++".hs-boot"
            _ -> error "bad Haskell output filename"


--do hPutStrLn o $ "Document contains XSD for target namespace "++
--                 targetNamespace e
  {-
  let (DTD name _ markup) = (getDtd . dtdParse inf) content
      decls = (nub . dtd2TypeDef) markup
      realname = if outf/="-" then mangle (trim outf)
                 else if null (localName name) then mangle (trim inf)
                 else mangle (localName name)
  in
  do hPutStrLn o ("module "++realname
                  ++" where\n\nimport Text.XML.HaXml.XmlContent"
                  ++"\nimport Text.XML.HaXml.OneOfN")
    --            ++"\nimport Char (isSpace)"
    --            ++"\nimport List (isPrefixOf)"
     hPutStrLn o "\n\n{-Type decls-}\n"
     (hPutStrLn o . render . vcat . map ppTypeDef) decls
     hPutStrLn o "\n\n{-Instance decls-}\n"
     mapM_ (hPutStrLn o . (++"\n") . render . mkInstance) decls
     hPutStrLn o "\n\n{-Done-}"
     hFlush o
  -}

{-
getDtd :: Maybe t -> t
getDtd (Just dtd) = dtd
getDtd (Nothing)  = error "No DTD in this document"

trim :: [Char] -> [Char]
trim name | '/' `elem` name  = (trim . tail . dropWhile (/='/')) name
          | '.' `elem` name  = takeWhile (/='.') name
          | otherwise        = name
-}

targetNamespace :: Element i -> String
targetNamespace (Elem qn attrs _) =
    if qn /= xsdSchema then "ERROR! top element not an xsd:schema tag"
    else maybe "ERROR! no targetNamespace specified" show
         (lookup (N "targetNamespace") attrs)

xsdSchema :: QName
xsdSchema = QN (nullNamespace{nsURI="http://www.w3.org/2001/XMLSchema"})
               "schema"

--  <xsd:schema xmlns:xsd="" xmlns:fpml="" targetNamespace="" version=""
--              attributeFormDefault="unqualified"
--              elementFormDefault="qualified">
