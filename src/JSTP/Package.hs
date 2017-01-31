module JSTP.Package where

import Control.Lens ((^?), ix)
import Control.Monad (unless)
import Control.Monad.Catch (MonadThrow)
import Data.LinkedHashMap as M 
import Data.List as L
import Data.String
import Data.Text as T
import Data.ByteString (ByteString)
import Data.Attoparsec.Text as A
import Data.Conduit
import Data.Conduit.Combinators as C
import Data.Word8 as W8
import Data.Conduit.Network

import Prelude as P

import JSTP.JSRS
import JSTP.Parser

makeServer = runTCPServer (serverSettings 8080 $ fromString "127.0.0.1")
           $ \appData -> appSource appData $$ omapE W8.toUpper =$ appSink appData
                          

data Package = Package
  { header   :: PackageHeader
  , category :: String
  , info     :: Maybe JField
  } deriving (Show)

data PackageHeader = PackageHeader
  { getId :: Int
  , getResourceId :: Maybe String
  } deriving (Show)

type PackageFormatError = String

toPackage :: JObject -> Either PackageFormatError Package
toPackage (JObject fieldsMap) = do
  (category, header) <- fromMaybeE fieldsCountErr headerField
  pHeader            <- fromMaybeE headerErr
                        $ fromJArray header >>= toPackageHeader
  return $ Package pHeader category info
    where headerField    = toList fieldsMap ^? ix 0
          info           = toList fieldsMap ^? ix 1
          fieldsCountErr = "Package must have one or two fields"
          headerErr      = "Header must be array with one or two elements"

toPackageHeader :: [JValue] -> Maybe PackageHeader
toPackageHeader arr@((JInt id):_) =
  Just $ PackageHeader id $ arr ^? ix 1 >>= fromJString
toPackageHeader _                 = Nothing
  
packageParser :: (Monad m, MonadThrow m) =>
  Conduit ByteString m (Result (Either PackageFormatError Package))
packageParser = fuse C.decodeUtf8 . fuse (splitC (== '\0')) . C.map
              $ A.parse (toPackage <$> (skipSpace *> pObject))

splitC :: Monad m => (Char -> Bool) -> Conduit Text m Text
splitC isCh = split' T.empty
  where split' acc = await >>= maybe (return ())
          (\text -> do
            let chunks = T.split isCh text
            P.mapM_ yield (P.init chunks)
            split' $ P.last chunks
          )

fromMaybeE :: a -> Maybe b -> Either a b
fromMaybeE x = maybe (Left x) Right

maybeE :: a -> (b -> c) -> Maybe b -> Either a c
maybeE x f = maybe (Left x) (Right . f)

{-
import Data.Functor ((<$>))
import Data.Monoid ( First(..)
                   , mconcat
                   )
import Data.Maybe ( fromJust
                  , fromMaybe
                  , isJust
                  , isNothing
                  )
import qualified Data.ByteString.UTF8 as B
import qualified Data.LinkedHashMap as M
import Text.Printf
import Text.ParserCombinators.Parsec (ParseError)

import JSTP.JSRS
import JSTP.Errors
import qualified JSTP.ResInfo as ResI
import qualified JSTP.ReqInfo as ReqI

data PackageInfo = ResInfo ResI.ResInfo
                 | ReqInfo ReqI.ReqInfo

data ReqOrRes = Request | Response

packageTypes :: [PackageFieldname]
packageTypes =
  [ "handshake"
  , "inspect"
  , "call"
  , "callback"
  ]

reqHandshake :: String -> B.ByteString
reqHandshake = B.fromString . printf "{handshake:[0,'%v']}"

toReqPackage :: JObject -> WithError Package
toReqPackage = toPackage' . map (mapSnd (fmap ReqInfo . )) $
  [ ("handshake", fmap (uncurry ReqI.Handshake) . takeReqHandshakeInfo)
  , ("inspect"  , fmap ReqI.Inspect . takeReqInspectInfo)
  , ("call"     , fmap (uncurry ReqI.Call) . takeReqCallInfo)
  ]


toResPackage :: JObject -> WithError Package
toResPackage = toPackage' . map (mapSnd (fmap ResInfo . )) $
  [ ("handshake", fmap ResI.Handshake . takePackageInfo fromJString)
  , ("callback" , fmap ResI.Callback  . takePackageInfo return)
  ]

mapSnd f (a, b) = (a, f b)
  
toPackage' :: [(Fieldname, JObject -> WithError PackageInfo)] 
           -> JObject -> WithError Package
toPackage' infoFuncs obj = fromMaybe (Left "Uknown package type") 
                         . getFirst . mconcat 
                         . map (First . takePackage obj)
                         $ infoFuncs

takePackageField :: JObject -> Maybe JField
takePackageField obj = getFirst . mconcat 
                     . map (First . takeField obj) 
                     $ packageTypes

takePackageValue = fmap snd . takePackageField

takePackageType = fmap fst . takePackageField

takePackageId :: JObject -> WithError Int
takePackageId obj = maybe 
  ( Left $ "No package field. Must be one from " ++ show packageTypes)
  ( maybe (Left "Package field must have id as first elements of array") Right
    . takeFirstInt
  )
  $ takePackageValue obj

takePackageInfo :: (JValue -> Maybe a) -> JObject  
                -> WithError (WithIdError a)
takePackageInfo takeOk obj = fromMaybe (Left "No ok or error field")
                           . getFirst . mconcat 
                           . map (First . takeInfo obj) $
  [ ("ok"   , okError , fmap Right . takeOk)
  , ("error", errError, fmap Left  . takeError)
  ]

takePackage :: JObject -> (Fieldname, JObject -> WithError PackageInfo) 
                       -> Maybe (WithError Package)
takePackage obj (name, infoFunc) = takeValueWith obj name $ 
  takePackage' obj infoFunc
  
takePackage' :: JObject -> (JObject -> WithError PackageInfo) 
             -> JValue -> WithError Package
takePackage' obj infoFunc package_field = do
  package_id <- maybe (Left idError) Right $ 
    takeFirstInt package_field
  package_info <- infoFunc obj
  return $ Package package_id package_info

type PackageFieldname = String

takeInterfaceName :: PackageFieldname -> JObject 
                  -> WithError ReqI.InterfaceName
takeInterfaceName fieldname obj = 
  fromMaybe (Left "No such package field") . takeInfo obj $
    ( fieldname
    , "No interface name"
    , takeSecondString
    )
 
takeAnotherField :: PackageFieldname -> JObject -> Maybe JField
takeAnotherField fieldname obj@(JObject fields) =
  let fields' = M.delete fieldname fields
      field = head $ M.toList fields'
  in if M.null fields'
     then Nothing
     else Just field

takeReqCallInfo :: JObject 
                -> WithError (ReqI.InterfaceName, ReqI.MethodInfo)
takeReqCallInfo obj = do
  interfaceName <- takeInterfaceName "call" obj
  methodInfo <- maybe ( Left "No method field" ) 
                      (\(name, val) ->
                         let arr = fromJArray val
                         in if isNothing arr
                            then Left "Args must be an array"
                            else Right (name, fromJust arr) 
                      ) 
                      $ takeAnotherField "call" obj
  return (interfaceName, methodInfo)

takeReqHandshakeInfo :: JObject 
                     -> WithError (ReqI.InterfaceName, Maybe ReqI.UserInfo)
takeReqHandshakeInfo obj = do
  interfaceName <- takeInterfaceName "handshake" obj
  let userField = takeAnotherField "handshake" obj
  userInfo <- maybe (Right Nothing) (\(userName, val) ->
                      let userInfo = fromJString val
                      in if isNothing userInfo
                         then Left "Session hash must be a string"
                         else Right $ Just (userName, fromJust userInfo)
                    ) userField 
  return (interfaceName, userInfo)

takeReqInspectInfo :: JObject -> WithError String
takeReqInspectInfo obj =  fromJust . takeInfo obj $
  ("inspect", "No interface name", takeSecondString)

takeInfo :: JObject -> (Fieldname, String, JValue -> Maybe a) 
                    -> Maybe (WithError a)
takeInfo obj (name, err, toInfo) =
  takeValueWith obj name $
    maybe (Left err) Right . toInfo

takeError :: JValue -> Maybe IdError
takeError (JArray ((JNumber id):JString msg:_)) = Just (floor id, msg)
takeError _ = Nothing

takeSecondString :: JValue -> Maybe String
takeSecondString (JArray (_:JString str:_)) = Just str
takeSecondString _ = Nothing

takeFirstInt :: JValue -> Maybe Int
takeFirstInt (JArray ((JNumber id):_)) = Just $ floor id
takeFirstInt _ = Nothing
  
idError = "Wrong packet id format"
okError = "Wrong ok format"
errError = "Wrong error format"

instance ToJSRSable Package where
  toJSRS (Package id (ResInfo (ResI.Handshake info))) = JObj $ fromList 
    [ ("handshake", JArray . return . intValue $ id)
    , resField
    ]
    where resField = case info of
            Right hash -> ("ok", JString hash)
            Left (errId, errMsg) -> ("error", JArray [ intValue errId
                                                     , JString errMsg
                                                     ])  
  toJSRS (Package id (ResInfo (ResI.Callback info))) = JObj $ fromList 
    [ ("callback", JArray . return . intValue $ id)
    , resField
    ]
    where resField = case info of
            Right val -> ("ok", val)
            Left (errId, errMsg) -> ("error", JArray [ intValue errId
                                                     , JString errMsg
                                                     ])  
  toJSRS (Package id (ReqInfo (ReqI.Inspect interfaceName))) = JObj $ fromList 
    [ ("inspect", JArray [intValue id, JString interfaceName]) ]
  toJSRS (Package id (ReqInfo (ReqI.Handshake interfaceName
                                              userInfoM))) = JObj . fromList $
    ("handshake", JArray [intValue id, JString interfaceName])
    : [userInfo | isJust userInfoM]
    where (userName, sessionHash) = fromJust userInfoM
          userInfo = (userName, JString sessionHash)
  toJSRS (Package id (ReqInfo (ReqI.Call interfaceName
                                         (methodName, methodArgs)))) = 
      JObj . fromList $
    [ ("call", JArray [intValue id, JString interfaceName])
    , (methodName, JArray methodArgs)
    ]

instance Show Package where
  show = show . toJSRS
-}
