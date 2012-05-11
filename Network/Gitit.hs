{-# LANGUAGE TypeFamilies, QuasiQuotes, MultiParamTypeClasses,
             TemplateHaskell, OverloadedStrings, FlexibleInstances,
             ScopedTypeVariables #-}
module Network.Gitit ( GititConfig (..)
                     , Page (..)
                     , Dir (..)
                     , HasGitit (..)
                     , Gitit (..)
                     , GititUser (..)
                     , GititMessage (..)
                     , Route (..)
                     , Tab (..)
                     , PageLayout (..)
                     , pageLayout
                     , makeDefaultPage
                     ) where

import Yesod
import Yesod.Static
import Yesod.Default.Handlers -- robots, favicon
import Language.Haskell.TH hiding (dyn)
import Data.List (isInfixOf, inits)
import Data.FileStore
import System.FilePath
import Text.Pandoc
import Control.Applicative
import qualified Data.Text as T
import Data.Text (Text)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy.UTF8 (toString )
import Text.Blaze.Html hiding (contents)
import Data.Monoid (Monoid, mappend)

-- This is defined in GHC 7.04+, but for compatibility we define it here.
infixr 5 <>
(<>) :: Monoid m => m -> m -> m
(<>) = mappend

-- | A Gitit wiki.  For an example of how a Gitit subsite
-- can be integrated into another Yesod app, see @src/gitit.hs@
-- in the package source.
data Gitit = Gitit{ config        :: GititConfig  -- ^ Wiki config options.
                  , filestore     :: FileStore    -- ^ Filestore with pages.
                  , getStatic     :: Static       -- ^ Static subsite.
                  }

instance Yesod Gitit where
  defaultLayout contents = do
    PageContent title headTags bodyTags <- widgetToPageContent $ do
      addWidget contents
    mmsg <- getMessage
    hamletToRepHtml [hamlet|
        $doctype 5
        <html>
          <head>
             <title>#{title}
             ^{headTags}
          <body>
             $maybe msg  <- mmsg
               <div #message>#{msg}
             ^{bodyTags}
        |]

-- | Configuration for a gitit wiki.
data GititConfig = GititConfig{
       wiki_path  :: FilePath    -- ^ Path to the repository.
     }

-- | Path to a wiki page.  Pages can't begin with '_'.
data Page = Page Text deriving (Show, Read, Eq)

instance PathMultiPiece Page where
  toPathMultiPiece (Page x) = T.splitOn "/" x
  fromPathMultiPiece (x:xs) = if "_" `T.isPrefixOf` x
                              then Nothing
                              else Just (Page $ T.intercalate "/" $ x:xs)
  fromPathMultiPiece []     = Nothing

instance ToMarkup Page where
  toMarkup (Page x) = toMarkup x

-- | Wiki directory.  Directories can't begin with '_'.
data Dir = Dir Text deriving (Show, Read, Eq)

instance PathMultiPiece Dir where
  toPathMultiPiece (Dir x) = T.splitOn "/" x
  fromPathMultiPiece (x:xs) = if "_" `T.isPrefixOf` x
                              then Nothing
                              else Just (Dir $ T.intercalate "/" $ x:xs)
  fromPathMultiPiece []     = Just $ Dir ""

instance ToMarkup Dir where
  toMarkup (Dir x) = toMarkup x

-- | A user.
data GititUser = GititUser{ gititUserName  :: String
                          , gititUserEmail :: String
                          } deriving Show

-- | A tab in the page layout.
data Tab  = ViewTab
          | EditTab
          | HistoryTab
          | DiscussTab
          | DiffTab
          deriving (Eq, Show)

-- | Page layout.
data PageLayout = PageLayout{
    pgName           :: Maybe Page
  , pgRevision       :: Maybe String
  , pgPrintable      :: Bool
  , pgShowPageTools  :: Bool
  , pgShowSiteNav    :: Bool
  , pgTabs           :: [Tab]
  , pgSelectedTab    :: Tab
  }

-- | Default page layout.
pageLayout = PageLayout{
    pgName           = Nothing
  , pgRevision       = Nothing
  , pgPrintable      = False
  , pgShowPageTools  = False
  , pgShowSiteNav    = True
  , pgTabs           = []
  , pgSelectedTab    = ViewTab
  }

-- Create GititMessages.
mkMessage "Gitit" "messages" "en"

-- | The master site containing a Gitit subsite must be an instance
-- of this typeclass.
class (Yesod master, RenderMessage master FormMessage,
       RenderMessage master GititMessage) => HasGitit master where
  -- | Return user information, if user is logged in, or nothing.
  maybeUser   :: GHandler sub master (Maybe GititUser)
  -- | Return user information or redirect to login page.
  requireUser :: GHandler sub master GititUser
  -- | Gitit subsite page layout.
  makePage :: PageLayout -> GWidget Gitit master () -> GHandler Gitit master RepHtml

-- Create routes.
mkYesodSub "Gitit" [ ClassP ''HasGitit [VarT $ mkName "master"]
 ] [parseRoutesNoCheck|
/ HomeR GET
/_static StaticR Static getStatic
/_index/*Dir  IndexR GET
/favicon.ico FaviconR GET
/robots.txt RobotsR GET
/_edit/*Page  EditR GET POST
/*Page     ViewR GET
|]

makeDefaultPage :: HasGitit master => PageLayout -> GWidget Gitit master () -> GHandler Gitit master RepHtml
makeDefaultPage layout content = do
  toMaster <- getRouteToMaster
  let logoRoute = toMaster $ StaticR $ StaticRoute ["img","logo.png"] []
  defaultLayout $ do
    addStylesheet $ toMaster $ StaticR $ StaticRoute ["css","custom.css"] []
    addScript $ toMaster $ StaticR $ StaticRoute ["js","jquery-1.7.2.min.js"] []
    [whamlet|
    <div #doc3 .yui-t1>
      <div #yui-main>
        <div #maincol .yui-b>
          ^{content}
      <div #sidebar .yui-b .first>
        <div #logo>
          <a href=@{toMaster HomeR}><img src=@{logoRoute} alt=logo></a>
        <div .sitenav>
          sitenav
          $maybe page <- pgName layout
            pagecontrols for #{page}
  |]

-- HANDLERS and utility functions, not exported:

pathForPage :: Page -> FilePath
pathForPage (Page page) = T.unpack page <.> "page"

pageForPath :: FilePath -> Page
pageForPath fp = Page . T.pack $
  if isPageFile fp then dropExtension fp else fp

isPage :: String -> Bool
isPage "" = False
isPage ('_':_) = False
isPage s = all (`notElem` "*?") s && not (".." `isInfixOf` s) && not ("/_" `isInfixOf` s)
-- for now, we disallow @*@ and @?@ in page names, because git filestore
-- does not deal with them properly, and darcs filestore disallows them.

isPageFile :: FilePath -> Bool
isPageFile f = takeExtension f == ".page"

isDiscussPage :: String -> Bool
isDiscussPage ('@':xs) = isPage xs
isDiscussPage _ = False

isDiscussPageFile :: FilePath -> Bool
isDiscussPageFile ('@':xs) = isPageFile xs
isDiscussPageFile _ = False

getHomeR :: HasGitit master => GHandler Gitit master RepHtml
getHomeR = getViewR (Page "Front Page")

getViewR :: HasGitit master => Page -> GHandler Gitit master RepHtml
getViewR page = do
  contents <- getRawContents page Nothing
  makePage pageLayout{ pgName = Just page } $ [whamlet|
    <h1 .title>#{page}
    ^{htmlPage contents}
  |]

getIndexR :: HasGitit master => Dir -> GHandler Gitit master RepHtml
getIndexR (Dir dir) = do
  fs <- filestore <$> getYesodSub
  listing <- liftIO $ directory fs $ T.unpack dir
  let isDiscussionPage (FSFile f) = isDiscussPageFile f
      isDiscussionPage (FSDirectory _) = False
  let prunedListing = filter (not . isDiscussionPage) listing
  let updirs = inits $ filter (not . T.null) $ toPathMultiPiece (Dir dir)
  toMaster <- getRouteToMaster
  makePage pageLayout{ pgName = Nothing } $ [whamlet|
    <h1 .title>
      $forall up <- updirs
        ^{upDir toMaster up}
    <div .index>
      <ul>
        $forall ent <- prunedListing
          ^{indexListing toMaster dir ent}
  |]

upDir :: (Route Gitit -> Route master) -> [Text] -> GWidget Gitit master ()
upDir toMaster fs = do
  let lastdir = case reverse fs of
                     (f:_)  -> f
                     []     -> "[root]"
  [whamlet|<a href=@{toMaster $ IndexR $ maybe (Dir "") id $ fromPathMultiPiece fs}>#{lastdir}/</a>|]

indexListing :: (Route Gitit -> Route master) -> Text -> Resource -> GWidget Gitit master ()
indexListing toMaster dir r = do
  let pref = if T.null dir
                then ""
                else dir <> "/"
  let fullName f = pref <> f'
                     where Page f' = pageForPath f
  let cls :: FilePath -> Text
      cls f = if isPageFile f then "page" else "upload"
  case r of
    (FSFile f) -> [whamlet|
          <li .#{cls f}>
            <a href=@{toMaster $ ViewR $ Page $ fullName f}>#{fullName f}</a>
          |]
    (FSDirectory f) -> [whamlet|
          <li .folder>
            <a href=@{toMaster $ IndexR $ Dir $ fullName f}>#{fullName f}</a>
          |]

getRawContents :: HasGitit master => Page -> Maybe RevisionId -> GHandler Gitit master ByteString
getRawContents page rev = do
  fs <- filestore <$> getYesodSub
  liftIO $ retrieve fs (pathForPage page) rev

htmlPage :: HasGitit master => ByteString -> GWidget Gitit master ()
htmlPage contents = do
  let mathjax_url = "https://d3eoax9i5htok0.cloudfront.net/mathjax/latest/MathJax.js?config=TeX-AMS-MML_HTMLorMML"
  let rendered = writeHtml defaultWriterOptions{
                     writerWrapText = False
                   , writerHtml5 = True
                   , writerHighlight = True
                   , writerHTMLMathMethod = MathJax $ T.unpack mathjax_url }
                   $ readMarkdown defaultParserState{
                      stateSmart = True }
                   $ toString contents
  addScriptRemote mathjax_url
  toWidget rendered

getEditR :: HasGitit master => Page -> GHandler Gitit master RepHtml
getEditR page = do
  requireUser
  contents <- Textarea . T.pack . toString <$> getRawContents page Nothing
  (form, enctype) <- generateFormPost $ editForm $ Just Edit{ editContents = contents, editComment = "" }
  toMaster <- getRouteToMaster
  makePage pageLayout{ pgName = Just page } $ do
    toWidget [lucius|
      textarea { width: 45em; height: 20em; font-family: monospace; }
      input[type='text'] { width: 45em; } 
      label { display: block; font-weight: bold; font-size: 80%; font-family: sans-serif; }
    |]
    [whamlet|
      <h1>#{page}</h1>
      <form method=post action=@{toMaster $ EditR page} enctype=#{enctype}>
        ^{form}
        <input type=submit>
    |]

postEditR :: HasGitit master
          => Page -> GHandler Gitit master RepHtml
postEditR page = do
  user <- requireUser
  ((res, _form), _enctype) <- runFormPost $ editForm Nothing
  fs <- filestore <$> getYesodSub
  case res of
       FormSuccess r -> do
          liftIO $ modify fs (pathForPage page) ""
            (Author (gititUserName user) (gititUserEmail user))
            (T.unpack $ editComment r) (filter (/='\r') . T.unpack $ unTextarea $ editContents r)
          -- TODO handle mergeinfo
          return ()
       _             -> return ()
  getViewR page

data Edit = Edit { editContents :: Textarea
                 , editComment  :: Text
                 } deriving Show

editForm :: HasGitit master
         => Maybe Edit
         -> Html
         -> MForm Gitit master (FormResult Edit, GWidget Gitit master ())
editForm mbedit = renderDivs $ Edit
    <$> areq textareaField (fieldSettingsLabel MsgPageSource)
           (editContents <$> mbedit)
    <*> areq commentField (fieldSettingsLabel MsgChangeDescription)
           (editComment <$> mbedit)
  where commentField = check validateNonempty textField
        validateNonempty y
          | T.null y = Left MsgValueRequired
          | otherwise = Right y
