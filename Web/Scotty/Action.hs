{-# LANGUAGE CPP               #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE LambdaCase #-}
{-# language ScopedTypeVariables #-}
module Web.Scotty.Action
    ( addHeader
    , body
    , bodyReader
    , file
    , rawResponse
    , files
    , filesOpts
    , W.ParseRequestBodyOptions, W.defaultParseRequestBodyOptions
    , finish
    , header
    , headers
    , html
    , htmlLazy
    , json
    , jsonData
    , formData
    , next
    , pathParam
    , captureParam
    , formParam
    , queryParam
    , pathParamMaybe
    , captureParamMaybe
    , formParamMaybe
    , queryParamMaybe
    , pathParams
    , captureParams
    , formParams
    , queryParams
    , throw
    , raw
    , nested
    , readEither
    , redirect
    , redirect300
    , redirect301
    , redirect302
    , redirect303
    , redirect304
    , redirect307
    , redirect308
    , request
    , setHeader
    , status
    , stream
    , text
    , textLazy
    , getResponseStatus
    , getResponseHeaders
    , getResponseContent
    , Param
    , Parsable(..)
    , ActionT
      -- private to Scotty
    , runAction
    ) where

import           Blaze.ByteString.Builder   (fromLazyByteString)

import qualified Control.Exception          as E
import           Control.Monad              (when)
import           Control.Monad.IO.Class     (MonadIO(..))
import UnliftIO (MonadUnliftIO(..))
import           Control.Monad.Reader       (MonadReader(..), ReaderT(..), asks)
import Control.Monad.Trans.Resource (withInternalState, runResourceT)

import           Control.Concurrent.MVar

import qualified Data.Aeson                 as A
import Data.Bool (bool)
import qualified Data.ByteString.Char8      as B
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.CaseInsensitive       as CI
import           Data.Traversable (for)
import qualified Data.HashMap.Strict        as HashMap
import           Data.Int
import           Data.List (foldl')
import           Data.Maybe                 (maybeToList)
import qualified Data.Text                  as T
import           Data.Text.Encoding         as STE
import qualified Data.Text.Lazy             as TL
import qualified Data.Text.Lazy.Encoding    as TLE
import           Data.Time                  (UTCTime)
import           Data.Time.Format           (parseTimeM, defaultTimeLocale)
import           Data.Typeable              (typeOf)
import           Data.Word

import           Network.HTTP.Types
-- not re-exported until version 0.11
#if !MIN_VERSION_http_types(0,11,0)
import           Network.HTTP.Types.Status
#endif
import           Network.Wai (Request, Response, StreamingBody, Application, requestHeaders)
import Network.Wai.Handler.Warp (InvalidRequest(..))
import qualified Network.Wai.Parse as W (FileInfo(..), ParseRequestBodyOptions, defaultParseRequestBodyOptions)

import           Numeric.Natural

import           Web.FormUrlEncoded (Form(..), FromForm(..))
import           Web.Scotty.Internal.Types
import           Web.Scotty.Util (mkResponse, addIfNotPresent, add, replace, lazyTextToStrictByteString, decodeUtf8Lenient)
import           UnliftIO.Exception (Handler(..), catches, throwIO)
import           System.IO (hPutStrLn, stderr)

import Network.Wai.Internal (ResponseReceived(..))


-- | Evaluate a route, catch all exceptions (user-defined ones, internal and all remaining, in this order)
--   and construct the 'Response'
--
-- 'Nothing' indicates route failed (due to Next) and pattern matching should try the next available route.
-- 'Just' indicates a successful response.
runAction :: MonadUnliftIO m =>
             Options
          -> Maybe (ErrorHandler m) -- ^ this handler (if present) is in charge of user-defined exceptions
          -> ActionEnv
          -> ActionT m () -- ^ Route action to be evaluated
          -> m (Maybe Response)
runAction options mh env action = do
  ok <- flip runReaderT env $ runAM $ tryNext $ action `catches` concat
    [ [actionErrorHandler]
    , maybeToList mh
    , [scottyExceptionHandler, someExceptionHandler options]
    ]
  res <- getResponse env
  return $ bool Nothing (Just $ mkResponse res) ok

-- | Exception handler in charge of 'ActionError'. Rethrowing 'Next' here is caught by 'tryNext'.
-- All other cases of 'ActionError' are converted to HTTP responses.
actionErrorHandler :: MonadIO m => ErrorHandler m
actionErrorHandler = Handler $ \case
  AERedirect s url -> do
    status s
    setHeader "Location" url
  AENext -> next
  AEFinish -> return ()

-- | Default handler for exceptions from scotty
scottyExceptionHandler :: MonadIO m => ErrorHandler m
scottyExceptionHandler = Handler $ \case
  RequestTooLarge -> do
    status status413
    text "Request body is too large"
  MalformedJSON bs err -> do
    status status400
    raw $ BL.unlines
      [ "jsonData: malformed"
      , "Body: " <> bs
      , "Error: " <> BL.fromStrict (encodeUtf8 err)
      ]
  FailedToParseJSON bs err -> do
    status status422
    raw $ BL.unlines
      [ "jsonData: failed to parse"
      , "Body: " <> bs
      , "Error: " <> BL.fromStrict (encodeUtf8 err)
      ]
  MalformedForm err -> do
    status status400
    raw $ BL.unlines
      [ "formData: malformed"
      , "Error: " <> BL.fromStrict (encodeUtf8 err)
      ]
  PathParameterNotFound k -> do
    status status500
    text $ T.unwords [ "Path parameter", k, "not found"]
  QueryParameterNotFound k -> do
    status status400
    text $ T.unwords [ "Query parameter", k, "not found"]
  FormFieldNotFound k -> do
    status status400
    text $ T.unwords [ "Query parameter", k, "not found"]
  FailedToParseParameter k v e -> do
    status status400
    text $ T.unwords [ "Failed to parse parameter", k, v, ":", e]
  WarpRequestException we -> case we of
    RequestHeaderFieldsTooLarge -> do
      status status413
    weo -> do -- FIXME fall-through case on InvalidRequest, it would be nice to return more specific error messages and codes here
      status status400
      text $ T.unwords ["Request Exception:", T.pack (show weo)]
  WaiRequestParseException we -> do
    status status413 -- 413 Content Too Large https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/413
    text $ T.unwords ["wai-extra Exception:", T.pack (show we)]
  ResourceTException rte -> do
    status status500
    text $ T.unwords ["resourcet Exception:", T.pack (show rte)]

-- | Uncaught exceptions turn into HTTP 500 Server Error codes
someExceptionHandler :: MonadIO m => Options -> ErrorHandler m
someExceptionHandler Options{verbose} =
  Handler $ \(E.SomeException e) -> do
    when (verbose > 0) $
      liftIO $
      hPutStrLn stderr $
      "Unhandled exception of " <> show (typeOf e) <> ": " <> show e
    status status500

-- | Throw an exception which can be caught within the scope of the current Action with 'catch'.
--
-- If the exception is not caught locally, another option is to implement a global 'Handler' (with 'defaultHandler') that defines its interpretation and a translation to HTTP error codes.
--
-- Uncaught exceptions turn into HTTP 500 responses.
throw :: (MonadIO m, E.Exception e) => e -> ActionT m a
throw = E.throw

-- | Abort execution of this action and continue pattern matching routes.
-- Like an exception, any code after 'next' is not executed.
--
-- NB : Internally, this is implemented with an exception that can only be
-- caught by the library, but not by the user.
--
-- As an example, these two routes overlap. The only way the second one will
-- ever run is if the first one calls 'next'.
--
-- > get "/foo/:bar" $ do
-- >   w :: Text <- pathParam "bar"
-- >   unless (w == "special") next
-- >   text "You made a request to /foo/special"
-- >
-- > get "/foo/:baz" $ do
-- >   w <- pathParam "baz"
-- >   text $ "You made a request to: " <> w
next :: Monad m => ActionT m a
next = E.throw AENext

-- | Synonym for 'redirect302'.
-- If you are unsure which redirect to use, you probably want this one.
--
-- > redirect "http://www.google.com"
--
-- OR
--
-- > redirect "/foo/bar"
redirect :: (Monad m) => T.Text -> ActionT m a
redirect = redirect302

-- | Redirect to given URL with status 300 (Multiple Choices). Like throwing
-- an uncatchable exception. Any code after the call to
-- redirect will not be run.
redirect300 :: (Monad m) => T.Text -> ActionT m a
redirect300 = redirectStatus status300

-- | Redirect to given URL with status 301 (Moved Permanently). Like throwing
-- an uncatchable exception. Any code after the call to
-- redirect will not be run.
redirect301 :: (Monad m) => T.Text -> ActionT m a
redirect301 = redirectStatus status301

-- | Redirect to given URL with status 302 (Found). Like throwing
-- an uncatchable exception. Any code after the call to
-- redirect will not be run.
redirect302 :: (Monad m) => T.Text -> ActionT m a
redirect302 = redirectStatus status302

-- | Redirect to given URL with status 303 (See Other). Like throwing
-- an uncatchable exception. Any code after the call to
-- redirect will not be run.
redirect303 :: (Monad m) => T.Text -> ActionT m a
redirect303 = redirectStatus status303

-- | Redirect to given URL with status 304 (Not Modified). Like throwing
-- an uncatchable exception. Any code after the call to
-- redirect will not be run.
redirect304 :: (Monad m) => T.Text -> ActionT m a
redirect304 = redirectStatus status304

-- | Redirect to given URL with status 307 (Temporary Redirect). Like throwing
-- an uncatchable exception. Any code after the call to
-- redirect will not be run.
redirect307 :: (Monad m) => T.Text -> ActionT m a
redirect307 = redirectStatus status307

-- | Redirect to given URL with status 308 (Permanent Redirect). Like throwing
-- an uncatchable exception. Any code after the call to
-- redirect will not be run.
redirect308 :: (Monad m) => T.Text -> ActionT m a
redirect308 = redirectStatus status308

redirectStatus :: (Monad m) => Status -> T.Text -> ActionT m a
redirectStatus s = E.throw . AERedirect s

-- | Finish the execution of the current action. Like throwing an uncatchable
-- exception. Any code after the call to finish will not be run.
--
-- /Since: 0.10.3/
finish :: (Monad m) => ActionT m a
finish = E.throw AEFinish

-- | Get the 'Request' object.
request :: Monad m => ActionT m Request
request = ActionT $ envReq <$> ask

-- | Get list of uploaded files.
--
-- NB: Loads all file contents in memory with options 'W.defaultParseRequestBodyOptions'
files :: MonadUnliftIO m => ActionT m [File BL.ByteString]
files = runResourceT $ withInternalState $ \istate -> do
  (_, fs) <- formParamsAndFilesWith istate W.defaultParseRequestBodyOptions
  for fs (\(fname, f) -> do
                   bs <- liftIO $ BL.readFile (W.fileContent f)
                   pure (fname, f{ W.fileContent = bs})
                   )


-- | Get list of uploaded temp files and form parameters decoded from multipart payloads.
--
-- NB the temp files are deleted when the continuation exits.
filesOpts :: MonadUnliftIO m =>
             W.ParseRequestBodyOptions
          -> ([Param] -> [File FilePath] -> ActionT m a) -- ^ temp files validation, storage etc
          -> ActionT m a
filesOpts prbo io = runResourceT $ withInternalState $ \istate -> do
  (ps, fs) <- formParamsAndFilesWith istate prbo
  io ps fs



-- | Get a request header. Header name is case-insensitive.
header :: (Monad m) => T.Text -> ActionT m (Maybe T.Text)
header k = do
    hs <- requestHeaders <$> request
    return $ fmap decodeUtf8Lenient $ lookup (CI.mk (encodeUtf8 k)) hs

-- | Get all the request headers. Header names are case-insensitive.
headers :: (Monad m) => ActionT m [(T.Text, T.Text)]
headers = do
    hs <- requestHeaders <$> request
    return [ ( decodeUtf8Lenient (CI.original k)
             , decodeUtf8Lenient v)
           | (k,v) <- hs ]

-- | Get the request body.
--
-- NB This loads the whole request body in memory at once.
body :: (MonadIO m) => ActionT m BL.ByteString
body = ActionT ask >>= (liftIO . envBody)

-- | Get an IO action that reads body chunks
--
-- * This is incompatible with 'body' since 'body' consumes all chunks.
bodyReader :: Monad m => ActionT m (IO B.ByteString)
bodyReader = ActionT $ envBodyChunk <$> ask

-- | Parse the request body as a JSON object and return it.
--
--   If the JSON object is malformed, this sets the status to
--   400 Bad Request, and throws an exception.
--
--   If the JSON fails to parse, this sets the status to
--   422 Unprocessable Entity.
--
--   These status codes are as per https://www.restapitutorial.com/httpstatuscodes.html.
--
-- NB : Internally this uses 'body'.
jsonData :: (A.FromJSON a, MonadIO m) => ActionT m a
jsonData = do
    b <- body
    when (b == "") $ throwIO $ MalformedJSON b "no data"
    case A.eitherDecode b of
      Left err -> throwIO $ MalformedJSON b $ T.pack err
      Right value -> case A.fromJSON value of
        A.Error err -> throwIO $ FailedToParseJSON b $ T.pack err
        A.Success a -> return a

-- | Parse the request body as @x-www-form-urlencoded@ form data and return it.
--
--   The form is parsed using 'urlDecodeAsForm'. If that returns 'Left', the
--   status is set to 400 and an exception is thrown.
formData :: (FromForm a, MonadUnliftIO m) => ActionT m a
formData = do
  form <- paramListToForm <$> formParams
  case fromForm form of
    Left err -> throwIO $ MalformedForm err
    Right value -> return value
  where
    -- This rather contrived implementation uses cons and reverse to avoid
    -- quadratic complexity when constructing a Form from a list of Param.
    -- It's equivalent to using HashMap.insertWith (++) which does have
    -- quadratic complexity due to appending at the end of list.
    paramListToForm :: [Param] -> Form
    paramListToForm = Form . fmap reverse . foldl' (\f (k, v) -> HashMap.alter (prependValue v) k f) HashMap.empty

    prependValue :: a -> Maybe [a] -> Maybe [a]
    prependValue v = Just . maybe [v] (v :)

-- | Synonym for 'pathParam'
captureParam :: (Parsable a, MonadIO m) => T.Text -> ActionT m a
captureParam = pathParam

-- | Look up a path parameter.
--
-- * Raises an exception which can be caught by 'catch' if parameter is not found. If the exception is not caught, scotty will return a HTTP error code 500 ("Internal Server Error") to the client.
--
-- * If the parameter is found, but 'parseParam' fails to parse to the correct type, 'next' is called.
--
-- /Since: 0.20/
pathParam :: (Parsable a, MonadIO m) => T.Text -> ActionT m a
pathParam k = do
  val <- ActionT $ lookup k . envPathParams <$> ask
  case val of
    Nothing -> throwIO $ PathParameterNotFound k
    Just v -> case parseParam $ TL.fromStrict v of
      Left _ -> next
      Right a -> pure a

-- | Look up a form parameter.
--
-- * Raises an exception which can be caught by 'catch' if parameter is not found. If the exception is not caught, scotty will return a HTTP error code 400 ("Bad Request") to the client.
--
-- * This function raises a code 400 also if the parameter is found, but 'parseParam' fails to parse to the correct type.
--
-- /Since: 0.20/
formParam :: (MonadUnliftIO m, Parsable b) => T.Text -> ActionT m b
formParam k = runResourceT $ withInternalState $ \istate -> do
  (ps, _) <- formParamsAndFilesWith istate W.defaultParseRequestBodyOptions
  case lookup k ps of
    Nothing -> throwIO $ FormFieldNotFound k
    Just v -> case parseParam $ TL.fromStrict v of
      Left e -> throwIO $ FailedToParseParameter k v (TL.toStrict e)
      Right a -> pure a

-- | Look up a query parameter.
--
-- * Raises an exception which can be caught by 'catch' if parameter is not found. If the exception is not caught, scotty will return a HTTP error code 400 ("Bad Request") to the client.
--
-- * This function raises a code 400 also if the parameter is found, but 'parseParam' fails to parse to the correct type.
--
-- /Since: 0.20/
queryParam :: (Parsable a, MonadIO m) => T.Text -> ActionT m a
queryParam = paramWith QueryParameterNotFound envQueryParams

-- | Look up a path parameter. Returns 'Nothing' if the parameter is not found or cannot be parsed at the right type.
--
-- NB : Doesn't throw exceptions. In particular, route pattern matching will not continue, so developers
-- must 'raiseStatus' or 'throw' to signal something went wrong.
--
-- /Since: 0.21/
pathParamMaybe :: (Parsable a, Monad m) => T.Text -> ActionT m (Maybe a)
pathParamMaybe = paramWithMaybe envPathParams

-- | Look up a capture parameter. Returns 'Nothing' if the parameter is not found or cannot be parsed at the right type.
--
-- NB : Doesn't throw exceptions. In particular, route pattern matching will not continue, so developers
-- must 'raiseStatus' or 'throw' to signal something went wrong.
--
-- /Since: 0.21/
captureParamMaybe :: (Parsable a, Monad m) => T.Text -> ActionT m (Maybe a)
captureParamMaybe = paramWithMaybe envPathParams

-- | Look up a form parameter. Returns 'Nothing' if the parameter is not found or cannot be parsed at the right type.
--
-- NB : Doesn't throw exceptions, so developers must 'raiseStatus' or 'throw' to signal something went wrong.
--
-- /Since: 0.21/
formParamMaybe :: (MonadUnliftIO m, Parsable a) =>
                  T.Text -> ActionT m (Maybe a)
formParamMaybe k = runResourceT $ withInternalState $ \istate -> do
  (ps, _) <- formParamsAndFilesWith istate W.defaultParseRequestBodyOptions
  case lookup k ps of
    Nothing -> pure Nothing
    Just v -> either (const $ pure Nothing) (pure . Just) $ parseParam $ TL.fromStrict v


-- | Look up a query parameter. Returns 'Nothing' if the parameter is not found or cannot be parsed at the right type.
--
-- NB : Doesn't throw exceptions, so developers must 'raiseStatus' or 'throw' to signal something went wrong.
--
-- /Since: 0.21/
queryParamMaybe :: (Parsable a, Monad m) => T.Text -> ActionT m (Maybe a)
queryParamMaybe = paramWithMaybe envQueryParams

data ParamType = PathParam
               | FormParam
               | QueryParam
instance Show ParamType where
  show = \case
    PathParam -> "path"
    FormParam -> "form"
    QueryParam -> "query"

paramWith :: (MonadIO m, Parsable b) =>
             (T.Text -> ScottyException)
          -> (ActionEnv -> [Param])
          -> T.Text -- ^ parameter name
          -> ActionT m b
paramWith toError f k = do
    val <- ActionT $ (lookup k . f) <$> ask
    case val of
      Nothing -> throwIO $ toError k
      Just v -> case parseParam $ TL.fromStrict v of
        Left e -> throwIO $ FailedToParseParameter k v (TL.toStrict e)
        Right a -> pure a

-- | Look up a parameter. Returns 'Nothing' if the parameter is not found or cannot be parsed at the right type.
--
-- NB : Doesn't throw exceptions.
--
-- /Since: 0.21/
paramWithMaybe :: (Monad m, Parsable b) =>
                  (ActionEnv -> [Param])
               -> T.Text -- ^ parameter name
               -> ActionT m (Maybe b)
paramWithMaybe f k = do
    val <- ActionT $ asks (lookup k . f)
    case val of
      Nothing -> pure Nothing
      Just v -> either (const $ pure Nothing) (pure . Just) $ parseParam $ TL.fromStrict v

-- | Get path parameters
pathParams :: Monad m => ActionT m [Param]
pathParams = paramsWith envPathParams

-- | Get path parameters
captureParams :: Monad m => ActionT m [Param]
captureParams = paramsWith envPathParams

-- | Get form parameters
formParams :: MonadUnliftIO m => ActionT m [Param]
formParams = runResourceT $ withInternalState $ \istate -> do
  fst <$> formParamsAndFilesWith istate W.defaultParseRequestBodyOptions

-- | Get query parameters
queryParams :: Monad m => ActionT m [Param]
queryParams = paramsWith envQueryParams

paramsWith :: Monad m => (ActionEnv -> a) -> ActionT m a
paramsWith f = ActionT (asks f)

-- === access the fields of the Response being constructed

-- | Access the HTTP 'Status' of the Response
--
-- /SINCE 0.21/
getResponseStatus :: (MonadIO m) => ActionT m Status
getResponseStatus = srStatus <$> getResponseAction
-- | Access the HTTP headers of the Response
--
-- /SINCE 0.21/
getResponseHeaders :: (MonadIO m) => ActionT m ResponseHeaders
getResponseHeaders = srHeaders <$> getResponseAction
-- | Access the content of the Response
--
-- /SINCE 0.21/
getResponseContent :: (MonadIO m) => ActionT m Content
getResponseContent = srContent <$> getResponseAction


-- | Minimum implemention: 'parseParam'
class Parsable a where
    -- | Take a 'T.Text' value and parse it as 'a', or fail with a message.
    parseParam :: TL.Text -> Either TL.Text a

    -- | Default implementation parses comma-delimited lists.
    --
    -- > parseParamList t = mapM parseParam (T.split (== ',') t)
    parseParamList :: TL.Text -> Either TL.Text [a]
    parseParamList t = mapM parseParam (TL.split (== ',') t)

-- No point using 'read' for Text, ByteString, Char, and String.
instance Parsable T.Text where parseParam = Right . TL.toStrict
instance Parsable TL.Text where parseParam = Right
instance Parsable B.ByteString where parseParam = Right . lazyTextToStrictByteString
instance Parsable BL.ByteString where parseParam = Right . TLE.encodeUtf8
-- | Overrides default 'parseParamList' to parse String.
instance Parsable Char where
    parseParam t = case TL.unpack t of
                    [c] -> Right c
                    _   -> Left "parseParam Char: no parse"
    parseParamList = Right . TL.unpack -- String
-- | Checks if parameter is present and is null-valued, not a literal '()'.
-- If the URI requested is: '/foo?bar=()&baz' then 'baz' will parse as (), where 'bar' will not.
instance Parsable () where
    parseParam t = if TL.null t then Right () else Left "parseParam Unit: no parse"

instance (Parsable a) => Parsable [a] where parseParam = parseParamList

instance Parsable Bool where
    parseParam t = if t' == TL.toCaseFold "true"
                   then Right True
                   else if t' == TL.toCaseFold "false"
                        then Right False
                        else Left "parseParam Bool: no parse"
        where t' = TL.toCaseFold t

instance Parsable Double where parseParam = readEither
instance Parsable Float where parseParam = readEither

instance Parsable Int where parseParam = readEither
instance Parsable Int8 where parseParam = readEither
instance Parsable Int16 where parseParam = readEither
instance Parsable Int32 where parseParam = readEither
instance Parsable Int64 where parseParam = readEither
instance Parsable Integer where parseParam = readEither

instance Parsable Word where parseParam = readEither
instance Parsable Word8 where parseParam = readEither
instance Parsable Word16 where parseParam = readEither
instance Parsable Word32 where parseParam = readEither
instance Parsable Word64 where parseParam = readEither
instance Parsable Natural where parseParam = readEither

-- | parse a UTCTime timestamp formatted as a ISO 8601 timestamp:
--
-- @yyyy-mm-ddThh:mm:ssZ@ , where the seconds can have a decimal part with up to 12 digits and no trailing zeros.
instance Parsable UTCTime where
    parseParam t =
      let
        fmt = "%FT%T%QZ"
      in
        case parseTimeM True defaultTimeLocale fmt (TL.unpack t) of
            Just d -> Right d
            _      -> Left $ "parseParam UTCTime: no parse of \"" <> t <> "\""

-- | Useful for creating 'Parsable' instances for things that already implement 'Read'. Ex:
--
-- > instance Parsable Int where parseParam = readEither
readEither :: Read a => TL.Text -> Either TL.Text a
readEither t = case [ x | (x,"") <- reads (TL.unpack t) ] of
                [x] -> Right x
                []  -> Left "readEither: no parse"
                _   -> Left "readEither: ambiguous parse"

-- | Set the HTTP response status.
status :: MonadIO m => Status -> ActionT m ()
status = modifyResponse . setStatus

-- Not exported, but useful in the functions below.
changeHeader :: MonadIO m
             => (CI.CI B.ByteString -> B.ByteString -> [(HeaderName, B.ByteString)] -> [(HeaderName, B.ByteString)])
             -> T.Text -> T.Text -> ActionT m ()
changeHeader f k =
  modifyResponse . setHeaderWith . f (CI.mk $ encodeUtf8 k) . encodeUtf8

-- | Add to the response headers. Header names are case-insensitive.
addHeader :: MonadIO m => T.Text -> T.Text -> ActionT m ()
addHeader = changeHeader add

-- | Set one of the response headers. Will override any previously set value for that header.
-- Header names are case-insensitive.
setHeader :: MonadIO m => T.Text -> T.Text -> ActionT m ()
setHeader = changeHeader replace

-- | Set the body of the response to the given 'T.Text' value. Also sets \"Content-Type\"
-- header to \"text/plain; charset=utf-8\" if it has not already been set.
text :: (MonadIO m) => T.Text -> ActionT m ()
text t = do
    changeHeader addIfNotPresent "Content-Type" "text/plain; charset=utf-8"
    raw $ BL.fromStrict $ encodeUtf8 t

-- | Set the body of the response to the given 'T.Text' value. Also sets \"Content-Type\"
-- header to \"text/plain; charset=utf-8\" if it has not already been set.
textLazy :: (MonadIO m) => TL.Text -> ActionT m ()
textLazy t = do
    changeHeader addIfNotPresent "Content-Type" "text/plain; charset=utf-8"
    raw $ TLE.encodeUtf8 t

-- | Set the body of the response to the given 'T.Text' value. Also sets \"Content-Type\"
-- header to \"text/html; charset=utf-8\" if it has not already been set.
html :: (MonadIO m) => T.Text -> ActionT m ()
html t = do
    changeHeader addIfNotPresent "Content-Type" "text/html; charset=utf-8"
    raw $ BL.fromStrict $ encodeUtf8 t

-- | Set the body of the response to the given 'T.Text' value. Also sets \"Content-Type\"
-- header to \"text/html; charset=utf-8\" if it has not already been set.
htmlLazy :: (MonadIO m) => TL.Text -> ActionT m ()
htmlLazy t = do
    changeHeader addIfNotPresent "Content-Type" "text/html; charset=utf-8"
    raw $ TLE.encodeUtf8 t

-- | Send a file as the response. Doesn't set the \"Content-Type\" header, so you probably
-- want to do that on your own with 'setHeader'. Setting a status code will have no effect
-- because Warp will overwrite that to 200 (see 'Network.Wai.Handler.Warp.Internal.sendResponse').
file :: MonadIO m => FilePath -> ActionT m ()
file = modifyResponse . setContent . ContentFile

rawResponse :: MonadIO m => Response -> ActionT m ()
rawResponse = modifyResponse . setContent . ContentResponse

-- | Set the body of the response to the JSON encoding of the given value. Also sets \"Content-Type\"
-- header to \"application/json; charset=utf-8\" if it has not already been set.
json :: (A.ToJSON a, MonadIO m) => a -> ActionT m ()
json v = do
    changeHeader addIfNotPresent "Content-Type" "application/json; charset=utf-8"
    raw $ A.encode v

-- | Set the body of the response to a Source. Doesn't set the
-- \"Content-Type\" header, so you probably want to do that on your
-- own with 'setHeader'.
stream :: MonadIO m => StreamingBody -> ActionT m ()
stream = modifyResponse . setContent . ContentStream

-- | Set the body of the response to the given 'BL.ByteString' value. Doesn't set the
-- \"Content-Type\" header, so you probably want to do that on your
-- own with 'setHeader'.
raw :: MonadIO m => BL.ByteString -> ActionT m ()
raw = modifyResponse . setContent . ContentBuilder . fromLazyByteString

-- | Nest a whole WAI application inside a Scotty handler.
-- See Web.Scotty for further documentation
nested :: (MonadIO m) => Network.Wai.Application -> ActionT m ()
nested app = do
  -- Is MVar really the best choice here? Not sure.
  r <- request
  ref <- liftIO $ newEmptyMVar
  _ <- liftIO $ app r (\res -> putMVar ref res >> return ResponseReceived)
  res <- liftIO $ readMVar ref
  rawResponse res
