{-# LANGUAGE RankNTypes #-}
-- | It should be noted that most of the code snippets below depend on the
-- OverloadedStrings language pragma.
--
-- Scotty is set up by default for development mode. For production servers,
-- you will likely want to modify 'Trans.settings' and the 'defaultHandler'. See
-- the comments on each of these functions for more information.
--
-- Please refer to the @examples@ directory and the @spec@ test suite for concrete use cases, e.g. constructing responses, exception handling and useful implementation details.
module Web.Scotty
    ( -- * Running 'scotty' servers
      scotty
    , scottyOpts
    , scottySocket
    , Options(..), defaultOptions
      -- ** scotty-to-WAI
    , scottyApp
      -- * Defining Middleware and Routes
      --
      -- | 'Middleware' and routes are run in the order in which they
      -- are defined. All middleware is run first, followed by the first
      -- route that matches. If no route matches, a 404 response is given.
    , middleware, get, post, put, delete, patch, options, addroute, matchAny, notFound, nested, setMaxRequestBodySize
      -- ** Route Patterns
    , capture, regex, function, literal
      -- ** Accessing the Request and its fields
    , request, header, headers, body, bodyReader
    , jsonData, formData
      -- ** Accessing Path, Form and Query Parameters
    , pathParam, captureParam, formParam, queryParam
    , pathParamMaybe, captureParamMaybe, formParamMaybe, queryParamMaybe
    , pathParams, captureParams, formParams, queryParams
      -- *** Files
    , files, filesOpts
      -- ** Modifying the Response
    , status, addHeader, setHeader
      -- ** Redirecting
    , redirect, redirect300, redirect301, redirect302, redirect303, redirect304, redirect307, redirect308
      -- ** Setting Response Body
      --
      -- | Note: only one of these should be present in any given route
      -- definition, as they completely replace the current 'Response' body.
    , text, html, file, json, stream, raw
      -- ** Accessing the fields of the Response
    , getResponseHeaders, getResponseStatus, getResponseContent
      -- ** Exceptions
    , throw, next, finish, defaultHandler
    , liftIO, catch
    , ScottyException(..)
      -- * Parsing Parameters
    , Param, Trans.Parsable(..), Trans.readEither
      -- * Types
    , ScottyM, ActionM, RoutePattern, File, Content(..), Kilobytes, ErrorHandler, Handler(..)
    , ScottyState, defaultScottyState
    -- ** Cookie functions
    , setCookie, setSimpleCookie, getCookie, getCookies, deleteCookie, Cookie.makeSimpleCookie
    -- ** Session Management
    , Session (..), SessionId, SessionJar, SessionStatus
    , createSessionJar, createUserSession, createSession, addSession
    , readSession, getUserSession, getSession, readUserSession
    , deleteSession, maintainSessions
    ) where

import qualified Web.Scotty.Trans as Trans

import qualified Control.Exception          as E
import Control.Monad.IO.Class
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.ByteString as BS
import Data.ByteString.Lazy.Char8 (ByteString)
import Data.Text.Lazy (Text, toStrict)
import qualified Data.Text as T

import Network.HTTP.Types (Status, StdMethod, ResponseHeaders)
import Network.Socket (Socket)
import Network.Wai (Application, Middleware, Request, StreamingBody)
import Network.Wai.Handler.Warp (Port)
import qualified Network.Wai.Parse as W

import Web.FormUrlEncoded (FromForm)
import Web.Scotty.Internal.Types (ScottyT, ActionT, ErrorHandler, Param, RoutePattern, Options, defaultOptions, File, Kilobytes, ScottyState, defaultScottyState, ScottyException, Content(..))
import UnliftIO.Exception (Handler(..), catch)
import qualified Web.Scotty.Cookie as Cookie 
import Web.Scotty.Session (Session (..), SessionId, SessionJar, SessionStatus , createSessionJar,
    createSession, addSession, maintainSessions)

{- $setup
>>> :{
import Control.Monad.IO.Class (MonadIO(..))
import qualified Network.HTTP.Client as H
import qualified Network.HTTP.Types as H
import qualified Network.Wai as W (httpVersion)
import qualified Data.ByteString.Lazy.Char8 as LBS (unpack)
import qualified Data.Text as T (pack)
import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Exception (bracket)
import qualified Web.Scotty as S (ScottyM, scottyOpts, get, text, regex, pathParam, Options(..), defaultOptions)
-- | GET an HTTP path
curl :: MonadIO m =>
        String -- ^ path
     -> m String -- ^ response body
curl path = liftIO $ do
  req0 <- H.parseRequest path
  let req = req0 { H.method = "GET"}
  mgr <- H.newManager H.defaultManagerSettings
  (LBS.unpack . H.responseBody) <$> H.httpLbs req mgr
-- | Fork a process, run a Scotty server in it and run an action while the server is running. Kills the scotty thread once the inner action is done.
withScotty :: S.ScottyM ()
           -> IO a -- ^ inner action, e.g. 'curl "localhost:3000/"'
           -> IO a
withScotty serv act = bracket (forkIO $ S.scottyOpts (S.defaultOptions{ S.verbose = 0 }) serv) killThread (\_ -> act)
:}
-}

type ScottyM = ScottyT IO
type ActionM = ActionT IO

-- | Run a scotty application using the warp server.
scotty :: Port -> ScottyM () -> IO ()
scotty p = Trans.scottyT p id

-- | Run a scotty application using the warp server, passing extra options.
scottyOpts :: Options -> ScottyM () -> IO ()
scottyOpts opts = Trans.scottyOptsT opts id

-- | Run a scotty application using the warp server, passing extra options,
-- and listening on the provided socket. This allows the user to provide, for
-- example, a Unix named socket, which can be used when reverse HTTP proxying
-- into your application.
scottySocket :: Options -> Socket -> ScottyM () -> IO ()
scottySocket opts sock = Trans.scottySocketT opts sock id

-- | Turn a scotty application into a WAI 'Application', which can be
-- run with any WAI handler.
scottyApp :: ScottyM () -> IO Application
scottyApp = Trans.scottyAppT defaultOptions id

-- | Global handler for user-defined exceptions.
defaultHandler :: ErrorHandler IO -> ScottyM ()
defaultHandler = Trans.defaultHandler

-- | Use given middleware. Middleware is nested such that the first declared
-- is the outermost middleware (it has first dibs on the request and last action
-- on the response). Every middleware is run on each request.
middleware :: Middleware -> ScottyM ()
middleware = Trans.middleware

-- | Nest a whole WAI application inside a Scotty handler.
-- Note: You will want to ensure that this route fully handles the response,
-- as there is no easy delegation as per normal Scotty actions.
-- Also, you will have to carefully ensure that you are expecting the correct routes,
-- this could require stripping the current prefix, or adding the prefix to your
-- application's handlers if it depends on them. One potential use-case for this
-- is hosting a web-socket handler under a specific route.
nested :: Application -> ActionM ()
nested = Trans.nested

-- | Set global size limit for the request body. Requests with body size exceeding the limit will not be
-- processed and an HTTP response 413 will be returned to the client. Size limit needs to be greater than 0,
-- otherwise the application will terminate on start.
setMaxRequestBodySize :: Kilobytes -> ScottyM ()
setMaxRequestBodySize = Trans.setMaxRequestBodySize

-- | Throw an exception which can be caught within the scope of the current Action with 'catch'.
--
-- If the exception is not caught locally, another option is to implement a global 'Handler' (with 'defaultHandler') that defines its interpretation and a translation to HTTP error codes.
--
-- Uncaught exceptions turn into HTTP 500 responses.
throw :: (E.Exception e) => e -> ActionM a
throw = Trans.throw

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
next :: ActionM ()
next = Trans.next

-- | Abort execution of this action. Like an exception, any code after 'finish'
-- is not executed.
--
-- As an example only requests to @\/foo\/special@ will include in the response
-- content the text message.
--
-- > get "/foo/:bar" $ do
-- >   w :: Text <- pathParam "bar"
-- >   unless (w == "special") finish
-- >   text "You made a request to /foo/special"
--
-- /Since: 0.10.3/
finish :: ActionM a
finish = Trans.finish

-- | Synonym for 'redirect302'.
-- If you are unsure which redirect to use, you probably want this one.
--
-- > redirect "http://www.google.com"
--
-- OR
--
-- > redirect "/foo/bar"
redirect :: Text -> ActionM a
redirect = Trans.redirect

-- | Redirect to given URL with status 300 (Multiple Choices). Like throwing
-- an uncatchable exception. Any code after the call to
-- redirect will not be run.
redirect300 :: Text -> ActionM a
redirect300 = Trans.redirect300

-- | Redirect to given URL with status 301 (Moved Permanently). Like throwing
-- an uncatchable exception. Any code after the call to
-- redirect will not be run.
redirect301 :: Text -> ActionM a
redirect301 = Trans.redirect301

-- | Redirect to given URL with status 302 (Found). Like throwing
-- an uncatchable exception. Any code after the call to
-- redirect will not be run.
redirect302 :: Text -> ActionM a
redirect302 = Trans.redirect302

-- | Redirect to given URL with status 303 (See Other). Like throwing
-- an uncatchable exception. Any code after the call to
-- redirect will not be run.
redirect303 :: Text -> ActionM a
redirect303 = Trans.redirect303

-- | Redirect to given URL with status 304 (Not Modified). Like throwing
-- an uncatchable exception. Any code after the call to
-- redirect will not be run.
redirect304 :: Text -> ActionM a
redirect304 = Trans.redirect304

-- | Redirect to given URL with status 307 (Temporary Redirect). Like throwing
-- an uncatchable exception. Any code after the call to
-- redirect will not be run.
redirect307 :: Text -> ActionM a
redirect307 = Trans.redirect307

-- | Redirect to given URL with status 308 (Permanent Redirect). Like throwing
-- an uncatchable exception. Any code after the call to
-- redirect will not be run.
redirect308 :: Text -> ActionM a
redirect308 = Trans.redirect308

-- | Get the 'Request' object.
request :: ActionM Request
request = Trans.request

-- | Get list of uploaded files.
--
-- NB: Loads all file contents in memory with options 'W.defaultParseRequestBodyOptions'
files :: ActionM [File ByteString]
files = Trans.files

-- | Get list of temp files and form parameters decoded from multipart payloads.
--
-- NB the temp files are deleted when the continuation exits
filesOpts :: W.ParseRequestBodyOptions
          -> ([Param] -> [File FilePath] -> ActionM a) -- ^ temp files validation, storage etc
          -> ActionM a
filesOpts = Trans.filesOpts

-- | Get a request header. Header name is case-insensitive.
header :: Text -> ActionM (Maybe Text)
header = Trans.header

-- | Get all the request headers. Header names are case-insensitive.
headers :: ActionM [(Text, Text)]
headers = Trans.headers

-- | Get the request body.
--
-- NB: loads the entire request body in memory
body :: ActionM ByteString
body = Trans.body

-- | Get an IO action that reads body chunks
--
-- * This is incompatible with 'body' since 'body' consumes all chunks.
bodyReader :: ActionM (IO BS.ByteString)
bodyReader = Trans.bodyReader

-- | Parse the request body as a JSON object and return it. Raises an exception if parse is unsuccessful.
--
-- NB: uses 'body' internally
jsonData :: FromJSON a => ActionM a
jsonData = Trans.jsonData

-- | Parse the request body as @x-www-form-urlencoded@ form data and return it. Raises an exception if parse is unsuccessful.
--
-- NB: uses 'body' internally
formData :: FromForm a => ActionM a
formData = Trans.formData

-- | Synonym for 'pathParam'
--
-- /Since: 0.20/
captureParam :: Trans.Parsable a => Text -> ActionM a
captureParam = Trans.captureParam . toStrict

-- | Get a path parameter.
--
-- * Raises an exception which can be caught by 'catch' if parameter is not found. If the exception is not caught, scotty will return a HTTP error code 500 ("Internal Server Error") to the client.
--
-- * If the parameter is found, but 'parseParam' fails to parse to the correct type, 'next' is called.
--
-- /Since: 0.21/
pathParam :: Trans.Parsable a => Text -> ActionM a
pathParam = Trans.pathParam . toStrict

-- | Get a form parameter.
--
-- * Raises an exception which can be caught by 'catch' if parameter is not found. If the exception is not caught, scotty will return a HTTP error code 400 ("Bad Request") to the client.
--
-- * This function raises a code 400 also if the parameter is found, but 'parseParam' fails to parse to the correct type.
--
-- /Since: 0.20/
formParam :: Trans.Parsable a => Text -> ActionM a
formParam = Trans.formParam . toStrict

-- | Get a query parameter.
--
-- * Raises an exception which can be caught by 'catch' if parameter is not found. If the exception is not caught, scotty will return a HTTP error code 400 ("Bad Request") to the client.
--
-- * This function raises a code 400 also if the parameter is found, but 'parseParam' fails to parse to the correct type.
--
-- /Since: 0.20/
queryParam :: Trans.Parsable a => Text -> ActionM a
queryParam = Trans.queryParam . toStrict


-- | Look up a path parameter. Returns 'Nothing' if the parameter is not found or cannot be parsed at the right type.
--
-- NB : Doesn't throw exceptions. In particular, route pattern matching will not continue, so developers
-- must 'raiseStatus' or 'throw' to signal something went wrong.
--
-- /Since: 0.21/
pathParamMaybe :: (Trans.Parsable a) => Text -> ActionM (Maybe a)
pathParamMaybe = Trans.pathParamMaybe . toStrict

-- | Synonym for 'pathParamMaybe'
--
-- /Since: 0.21/
captureParamMaybe :: (Trans.Parsable a) => Text -> ActionM (Maybe a)
captureParamMaybe = Trans.pathParamMaybe . toStrict

-- | Look up a form parameter. Returns 'Nothing' if the parameter is not found or cannot be parsed at the right type.
--
-- NB : Doesn't throw exceptions, so developers must 'raiseStatus' or 'throw' to signal something went wrong.
--
-- /Since: 0.21/
formParamMaybe :: (Trans.Parsable a) => Text -> ActionM (Maybe a)
formParamMaybe = Trans.formParamMaybe . toStrict

-- | Look up a query parameter. Returns 'Nothing' if the parameter is not found or cannot be parsed at the right type.
--
-- NB : Doesn't throw exceptions, so developers must 'raiseStatus' or 'throw' to signal something went wrong.
--
-- /Since: 0.21/
queryParamMaybe :: (Trans.Parsable a) => Text -> ActionM (Maybe a)
queryParamMaybe = Trans.queryParamMaybe . toStrict

-- | Synonym for 'pathParams'
captureParams :: ActionM [Param]
captureParams = Trans.captureParams
-- | Get path parameters
pathParams :: ActionM [Param]
pathParams = Trans.pathParams
-- | Get form parameters
formParams :: ActionM [Param]
formParams = Trans.formParams
-- | Get query parameters
queryParams :: ActionM [Param]
queryParams = Trans.queryParams


-- | Set the HTTP response status. Default is 200.
status :: Status -> ActionM ()
status = Trans.status

-- | Add to the response headers. Header names are case-insensitive.
addHeader :: Text -> Text -> ActionM ()
addHeader = Trans.addHeader

-- | Set one of the response headers. Will override any previously set value for that header.
-- Header names are case-insensitive.
setHeader :: Text -> Text -> ActionM ()
setHeader = Trans.setHeader

-- | Set the body of the response to the given 'Text' value. Also sets \"Content-Type\"
-- header to \"text/plain; charset=utf-8\" if it has not already been set.
text :: Text -> ActionM ()
text = Trans.text

-- | Set the body of the response to the given 'Text' value. Also sets \"Content-Type\"
-- header to \"text/html; charset=utf-8\" if it has not already been set.
html :: Text -> ActionM ()
html = Trans.html

-- | Send a file as the response. Doesn't set the \"Content-Type\" header, so you probably
-- want to do that on your own with 'setHeader'.
file :: FilePath -> ActionM ()
file = Trans.file

-- | Set the body of the response to the JSON encoding of the given value. Also sets \"Content-Type\"
-- header to \"application/json; charset=utf-8\" if it has not already been set.
json :: ToJSON a => a -> ActionM ()
json = Trans.json

-- | Set the body of the response to a StreamingBody. Doesn't set the
-- \"Content-Type\" header, so you probably want to do that on your
-- own with 'setHeader'.
stream :: StreamingBody -> ActionM ()
stream = Trans.stream

-- | Set the body of the response to the given 'BL.ByteString' value. Doesn't set the
-- \"Content-Type\" header, so you probably want to do that on your own with 'setHeader'.
raw :: ByteString -> ActionM ()
raw = Trans.raw


-- | Access the HTTP 'Status' of the Response
--
-- /Since: 0.21/
getResponseStatus :: ActionM Status
getResponseStatus = Trans.getResponseStatus
-- | Access the HTTP headers of the Response
--
-- /Since: 0.21/
getResponseHeaders :: ActionM ResponseHeaders
getResponseHeaders = Trans.getResponseHeaders
-- | Access the content of the Response
--
-- /Since: 0.21/
getResponseContent :: ActionM Content
getResponseContent = Trans.getResponseContent


-- | get = 'addroute' 'GET'
get :: RoutePattern -> ActionM () -> ScottyM ()
get = Trans.get

-- | post = 'addroute' 'POST'
post :: RoutePattern -> ActionM () -> ScottyM ()
post = Trans.post

-- | put = 'addroute' 'PUT'
put :: RoutePattern -> ActionM () -> ScottyM ()
put = Trans.put

-- | delete = 'addroute' 'DELETE'
delete :: RoutePattern -> ActionM () -> ScottyM ()
delete = Trans.delete

-- | patch = 'addroute' 'PATCH'
patch :: RoutePattern -> ActionM () -> ScottyM ()
patch = Trans.patch

-- | options = 'addroute' 'OPTIONS'
options :: RoutePattern -> ActionM () -> ScottyM ()
options = Trans.options

-- | Add a route that matches regardless of the HTTP verb.
matchAny :: RoutePattern -> ActionM () -> ScottyM ()
matchAny = Trans.matchAny

-- | Specify an action to take if nothing else is found. Note: this _always_ matches,
-- so should generally be the last route specified.
notFound :: ActionM () -> ScottyM ()
notFound = Trans.notFound

{- | Define a route with a 'StdMethod', a route pattern representing the path spec,
and an 'Action' which may modify the response.

> get "/" $ text "beam me up!"

The path spec can include values starting with a colon, which are interpreted
as /captures/. These are parameters that can be looked up with 'pathParam'.

>>> :{
let server = S.get "/foo/:bar" (S.pathParam "bar" >>= S.text)
 in do
      withScotty server $ curl "http://localhost:3000/foo/something"
:}
"something"
-}
addroute :: StdMethod -> RoutePattern -> ActionM () -> ScottyM ()
addroute = Trans.addroute


{- | Match requests using a regular expression.
Named captures are not yet supported.

>>> :{
let server = S.get (S.regex "^/f(.*)r$") $ do
                cap <- S.pathParam "1"
                S.text cap
 in do
      withScotty server $ curl "http://localhost:3000/foo/bar"
:}
"oo/ba"
-}
regex :: String -> RoutePattern
regex = Trans.regex

-- | Standard Sinatra-style route. Named captures are prepended with colons.
--   This is the default route type generated by OverloadedString routes. i.e.
--
-- > get (capture "/foo/:bar") $ ...
--
--   and
--
-- > {-# LANGUAGE OverloadedStrings #-}
-- > ...
-- > get "/foo/:bar" $ ...
--
--   are equivalent.
capture :: String -> RoutePattern
capture = Trans.capture


{- | Build a route based on a function which can match using the entire 'Request' object.
'Nothing' indicates the route does not match. A 'Just' value indicates
a successful match, optionally returning a list of key-value pairs accessible by 'param'.

>>> :{
let server = S.get (function $ \req -> Just [("version", T.pack $ show $ W.httpVersion req)]) $ do
                v <- S.pathParam "version"
                S.text v
 in do
      withScotty server $ curl "http://localhost:3000/"
:}
"HTTP/1.1"
-}
function :: (Request -> Maybe [Param]) -> RoutePattern
function = Trans.function

-- | Build a route that requires the requested path match exactly, without captures.
literal :: String -> RoutePattern
literal = Trans.literal


-- | Retrieves a session by its ID from the session jar.
getSession :: SessionJar a -> SessionId -> ActionM (Either SessionStatus (Session a))
getSession = Trans.getSession
    
-- | Deletes a session by its ID from the session jar.
deleteSession :: SessionJar a -> SessionId -> ActionM ()
deleteSession = Trans.deleteSession
    
{- | Retrieves the current user's session based on the "sess_id" cookie.
| Returns `Left SessionStatus` if the session is expired or does not exist.
-}
getUserSession :: SessionJar a -> ActionM (Either SessionStatus (Session a))
getUserSession = Trans.getUserSession

-- | Reads the content of a session by its ID.
readSession :: SessionJar a -> SessionId -> ActionM (Either SessionStatus a)
readSession = Trans.readSession

-- | Reads the content of the current user's session.
readUserSession ::SessionJar a -> ActionM (Either SessionStatus a)
readUserSession = Trans.readUserSession

-- | Creates a new session for a user, storing the content and setting a cookie.
createUserSession :: 
    SessionJar a -- ^ SessionJar, which can be created by createSessionJar
    -> Maybe Int  -- ^ Optional expiration time (in seconds)
    -> a          -- ^ Content
    -> ActionM (Session a)
createUserSession = Trans.createUserSession

-- Cookie functions

-- | Set a cookie, with full access to its options (see 'SetCookie')
setCookie :: Cookie.SetCookie -> ActionM ()
setCookie = Cookie.setCookie

-- | 'makeSimpleCookie' and 'setCookie' combined.
setSimpleCookie :: T.Text -- ^ name
                -> T.Text -- ^ value
                -> ActionM ()
setSimpleCookie = Cookie.setSimpleCookie

-- | Lookup one cookie name
getCookie :: T.Text -- ^ name
            -> ActionM (Maybe T.Text)
getCookie = Cookie.getCookie

-- | Returns all cookies
getCookies :: ActionM Cookie.CookiesText
getCookies = Cookie.getCookies

-- | Browsers don't directly delete a cookie, but setting its expiry to a past date (e.g. the UNIX epoch) 
-- ensures that the cookie will be invalidated 
-- (whether and when it will be actually deleted by the browser seems to be browser-dependent).
deleteCookie :: T.Text -- ^ name
             -> ActionM ()
deleteCookie = Cookie.deleteCookie 
