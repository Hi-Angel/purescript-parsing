-- | This module is for finding patterns in a `String`, and also
-- | replacing or splitting on the found patterns.
-- | This activity is traditionally done with
-- | [__Regex__](https://pursuit.purescript.org/packages/purescript-strings/docs/Data.String.Regex),
-- | but this module uses parsers instead for the pattern matching.
-- |
-- | Functions in this module are *ways to run a parser* on an input `String`,
-- | like `runParser` or `runParserT`.
-- |
-- | #### Why would we want to do pattern matching and substitution with parsers instead of regular expressions?
-- |
-- | * Monadic parsers have a nicer syntax than
-- |   [regular expressions](https://en.wikipedia.org/wiki/Regular_expression),
-- |   which are notoriously
-- |   [difficult to read](https://en.wikipedia.org/wiki/Write-only_language).
-- |   With monadic parsers we can perform textual pattern-matching in plain
-- |   PureScript rather than using a special regex domain-specific
-- |   programming language.
-- |
-- | * Regular expressions can do “group capture” on sections of the matched
-- |   pattern, but they can only return stringy lists of the capture groups. Parsers
-- |   can construct typed data structures based on the capture groups, guaranteeing
-- |   no disagreement between the pattern rules and the rules that we're using
-- |   to build data structures based on the pattern matches.
-- |
-- |   For example, consider
-- |   scanning a string for numbers. A lot of different things can look like a number,
-- |   and can have leading plus or minus signs, or be in scientific notation, or
-- |   have commas, or whatever. If we try to parse all of the numbers out of a string
-- |   using regular expressions, then we have to make sure that the regular expression
-- |   and the string-to-number conversion function agree about exactly what is
-- |   and what isn't a numeric string. We can get into an awkward situation in which
-- |   the regular expression says it has found a numeric string but the
-- |   string-to-number conversion function fails. A typed parser will perform both
-- |   the pattern match and the conversion, so it will never be in that situation.
-- |   [Parse, don't validate.](https://lexi-lambda.github.io/blog/2019/11/05/parse-don-t-validate/)
-- |
-- | * Regular expressions are only able to pattern-match
-- |   [regular grammars](https://en.wikipedia.org/wiki/Chomsky_hierarchy#The_hierarchy).
-- |   Monadic parsers are able pattern-match context-free (by recursion)
-- |   or context-sensitive (by monad transformer) grammars.
-- |
-- | * The replacement expression for a traditional regular expression-based
-- |   substitution command is usually just a string template in which
-- |   the *Nth* “capture group” can be inserted with the syntax `\N`. With
-- |   this library, instead of a template, we get
-- |   an `editor` function which can perform any computation, including `Effect`s.
-- |
-- | #### Implementation Notes
-- |
-- | All of the functions in this module work by calling `runParserT`
-- | with the `anyTill` combinator.
-- | We can expect the speed of parser-based pattern matching to be
-- | about 10× worse than regex-based pattern matching in a JavaScript
-- | runtime environment.
-- | This module is based on the Haskell packages
-- | [__replace-megaparsec__](https://hackage.haskell.org/package/replace-megaparsec)
-- | and
-- | [__replace-attoparsec__](https://hackage.haskell.org/package/replace-attoparsec).
-- |
module Parsing.String.Replace
  ( breakCap
  , breakCapT
  , splitCap
  , splitCapT
  , streamEdit
  , streamEditT
  ) where

import Prelude

import Control.Monad.Rec.Class (class MonadRec, Step(..), tailRecM)
import Control.Monad.ST (ST)
import Control.Monad.ST.Global (Global, toEffect)
import Data.Array as Array
import Data.Array.ST (STArray)
import Data.Array.ST as Array.ST
import Data.Array.ST.Partial as Array.ST.Partial
import Data.Either (Either(..), hush)
import Data.List (List(..), foldl, uncons, (:))
import Data.List as List
import Data.List.NonEmpty (NonEmptyList, fromList, singleton)
import Data.Maybe (Maybe(..), fromJust, isJust, maybe)
import Data.Newtype (unwrap, wrap)
import Data.Nullable (Nullable, notNull, null)
import Data.String (CodePoint, joinWith)
import Data.String as CodePoint
import Data.String as String
import Data.Tuple (Tuple(..))
import Data.Tuple.Nested (T3, (/\))
import Effect.Unsafe (unsafePerformEffect)
import Parsing (ParseState(..), Parser, ParserT, Position(..), getParserT, position, runParserT)
import Parsing.Combinators (optionMaybe, try)
import Parsing.String (anyCodePoint, anyTill, rest)
import Partial.Unsafe (unsafePartial)
import Unsafe.Coerce (unsafeCoerce)

-- | Monad transformer version of `breakCap`. The `sep` parser will run
-- | in the monad context.
breakCapT
  :: forall m a
   . (Monad m)
  => (MonadRec m)
  => String
  -> ParserT String m a
  -> m (Maybe (T3 String a String))
breakCapT input sep = hush <$> runParserT input go
  where
  go = do
    Tuple prefix cap <- anyTill sep
    ParseState suffix _ _ <- getParserT
    pure $ prefix /\ cap /\ suffix

-- | #### Break on and capture one pattern
-- |
-- | Find the first occurence of a pattern in a text stream, capture the found
-- | pattern, and break the input text stream on the found pattern.
-- |
-- | This function can be used instead of
-- | [Data.String.indexOf](https://pursuit.purescript.org/packages/purescript-strings/docs/Data.String#v:indexOf)
-- | or
-- | [Data.String.Regex.search](https://pursuit.purescript.org/packages/purescript-strings/docs/Data.String.Regex#v:search)
-- | or
-- | [Data.String.Regex.replace](https://pursuit.purescript.org/packages/purescript-strings/docs/Data.String.Regex#v:replace)
-- | and it allows using a parser for the pattern search.
-- |
-- | This function can be used instead of
-- | [Data.String.takeWhile](https://pursuit.purescript.org/packages/purescript-strings/docs/Data.String#v:takeWhile)
-- | or
-- | [Data.String.dropWhile](https://pursuit.purescript.org/packages/purescript-strings/docs/Data.String#v:dropWhile)
-- | and it is predicated beyond more than just the next single `CodePoint`.
-- |
-- | #### Output
-- |
-- | - `Nothing` when no pattern match was found.
-- | - `Just (prefix /\ parse_result /\ suffix)` for the result of parsing the
-- |   pattern match, and the `prefix` string before and the `suffix` string
-- |   after the pattern match. `prefix` and `suffix` may be zero-length strings.
-- |
-- | #### Access the matched section of text
-- |
-- | If you want to capture the matched string, then combine the pattern
-- | parser `sep` with `match`.
-- |
-- | With the matched string, we can reconstruct the input string.
-- | For all `input`, `sep`, if
-- |
-- | ```purescript
-- | let (Just (prefix /\ (infix /\ _) /\ suffix)) =
-- |       breakCap input (match sep)
-- | ```
-- |
-- | then
-- |
-- | ```purescript
-- | input == prefix <> infix <> suffix
-- | ```
-- | #### Example
-- |
-- | Find the first pattern match and break the input string on the pattern.
-- |
-- | ```purescript
-- | breakCap "hay needle hay" (string "needle")
-- | ```
-- |
-- | Result:
-- |
-- | ```purescript
-- | Just ("hay " /\ "needle" /\ " hay")
-- | ```
-- |
-- | #### Example
-- |
-- | Find the first pattern match, capture the matched text and the parsed result.
-- |
-- | ```purescript
-- | breakCap "abc 123 def" (match intDecimal)
-- | ```
-- |
-- | Result:
-- |
-- | ```purescript
-- | Just ("abc " /\ ("123" /\ 123) /\ " def")
-- | ```

breakCap
  :: forall a
   . String
  -> Parser String a
  -> Maybe (T3 String a String)
breakCap input sep = unwrap $ breakCapT input sep

-- | Monad transformer version of `splitCap`. The `sep` parser will run in the
-- | monad context.
-- |
-- | #### Example
-- |
-- | Count the pattern matches.
-- |
-- | Parse in a `State` monad to remember state in the parser. This
-- | stateful `letterCount` parser counts
-- | the number of pattern matches which occur in the input, and also
-- | tags each match with its index.
-- |
-- |
-- | ```purescript
-- | letterCount :: ParserT String (State Int) (Tuple Char Int)
-- | letterCount = do
-- |   x <- letter
-- |   i <- modify (_+1)
-- |   pure (x /\ i)
-- |
-- | flip runState 0 $ splitCapT "A B" letterCount
-- | ```
-- |
-- | Result:
-- |
-- | ```purescript
-- | [Right ('A' /\ 1), Left " ", Right ('B' /\ 2)] /\ 2
-- | ```
splitCapT
  :: forall m a
   . Monad m
  => MonadRec m
  => String
  -> ParserT String m a
  -> m (NonEmptyList (Either String a))
splitCapT input sep = do
  runParserT input (Tuple <$> (splitCapCombinator sep) <*> rest) >>= case _ of
    Left _ -> pure (singleton (Left input))
    Right (Tuple { carry, rlist } remain) -> do
      let
        term =
          maybe remain (\cp -> CodePoint.singleton cp <> remain) carry
      if List.null rlist then
        if String.null term then
          pure (singleton (Left input))
        else
          pure (singleton (Left term))
      else
        pure $ unsafePartial $ fromJust $ fromList $ foldl
          ( \ls (Tuple unmatched matched) ->
              if String.null unmatched then
                (Right matched : ls)
              else
                (Left unmatched : Right matched : ls)
          )
          ( if String.null term then
              Nil
            else
              Left term : Nil
          )
          rlist

-- | Internal splitCap helper combinator. Returns
-- | - The reversed `many anyTill` List.
-- | - The length of the nonempty tuple elements in the List.
-- | - One CodePoint carried over from the last parser match, in case the
-- |   parser succeeded without consuming any input. This is where most
-- |   of the complexity comes from.
-- | We have to make sure we reasonably handle two cases:
-- | 1. The sep parser fails but consumes input
-- | 2. The sep parser succeeds but does not consume any input
splitCapCombinator
  :: forall m a
   . Monad m
  => ParserT String m a
  -> ParserT String m { carry :: Maybe CodePoint, rlist :: List (Tuple String a), arraySize :: Int }

splitCapCombinator sep = tailRecM accum { carry: Nothing, rlist: Nil, arraySize: 0 }
  where
  posSep = do
    Position { index: posIndex1 } <- position
    x <- sep
    Position { index: posIndex2 } <- position
    pure $ posIndex1 /\ x /\ posIndex2

  accum
    :: { carry :: Maybe CodePoint, rlist :: List (Tuple String a), arraySize :: Int }
    -> ParserT String m
         ( Step
             { carry :: Maybe CodePoint, rlist :: List (Tuple String a), arraySize :: Int }
             { carry :: Maybe CodePoint, rlist :: List (Tuple String a), arraySize :: Int }
         )
  accum { carry, rlist, arraySize } = do
    optionMaybe (try $ anyTill posSep) >>= case _ of
      Just (Tuple unmatched (posIndex1 /\ matched /\ posIndex2)) -> do
        let
          carry_unmatched = case carry of
            Nothing -> unmatched
            Just cp -> CodePoint.singleton cp <> unmatched
        if posIndex2 == posIndex1 then do
          -- sep succeeded but consumed no input, so advance by one codepoint and
          -- carry the codepoint over to cons to the next unmatched
          carryNext <- optionMaybe anyCodePoint
          if isJust carryNext then
            pure $ Loop
              { carry: carryNext
              , rlist: Tuple carry_unmatched matched : rlist
              , arraySize: if String.null carry_unmatched then arraySize + 1 else arraySize + 2
              }
          else
            pure $ Done -- no more input, so we're done
              { carry: carryNext
              , rlist: Tuple carry_unmatched matched : rlist
              , arraySize: if String.null carry_unmatched then arraySize + 1 else arraySize + 2
              }
        else
          pure $ Loop
            { carry: Nothing
            , rlist: Tuple carry_unmatched matched : rlist
            , arraySize: if String.null carry_unmatched then arraySize + 1 else arraySize + 2
            }
      Nothing -> -- no pattern found, so we're done

        pure (Done { carry, rlist, arraySize })

-- | #### Split on and capture all patterns
-- |
-- | Find all occurences of the pattern parser `sep`, split the input string,
-- | capture all the patterns and the splits.
-- |
-- | This function can be used instead of
-- | [Data.String.Common.split](https://pursuit.purescript.org/packages/purescript-strings/docs/Data.String.Common#v:split)
-- | or
-- | [Data.String.Regex.split](https://pursuit.purescript.org/packages/purescript-strings/docs/Data.String.Regex#v:split)
-- | or
-- | [Data.String.Regex.match](https://pursuit.purescript.org/packages/purescript-strings/docs/Data.String.Regex#v:match)
-- | or
-- | [Data.String.Regex.search](https://pursuit.purescript.org/packages/purescript-strings/docs/Data.String.Regex#v:search).
-- |
-- | The input string will be split on every leftmost non-overlapping occurence
-- | of the pattern `sep`. The output list will contain
-- | the parsed result of input string sections which match the `sep` pattern
-- | in `Right`, and non-matching sections in `Left`.
-- |
-- | #### Access the matched section of text
-- |
-- | If you want to capture the matched strings, then combine the pattern
-- | parser `sep` with the `match` combinator.
-- |
-- | With the matched strings, we can reconstruct the input string.
-- | For all `input`, `sep`, if
-- |
-- | ```purescript
-- | let output = splitCap input (match sep)
-- | ```
-- |
-- | then
-- |
-- | ```purescript
-- | input == fold (either identity fst <$> output)
-- | ```
-- |
-- | #### Example
-- |
-- | Split the input string on all `Int` pattern matches.
-- |
-- | ```purescript
-- | splitCap "hay 1 straw 2 hay" intDecimal
-- | ```
-- |
-- | Result:
-- |
-- | ```
-- | [Left "hay ", Right 1, Left " straw ", Right 2, Left " hay"]
-- | ```
-- |
-- | #### Example
-- |
-- | Find the beginning positions of all pattern matches in the input.
-- |
-- | ```purescript
-- | catMaybes $ hush <$> splitCap ".𝝺...\n...𝝺." (position <* string "𝝺")
-- | ```
-- |
-- | Result:
-- |
-- | ```purescript
-- | [ Position {index: 1, line: 1, column: 2 }
-- | , Position { index: 9, line: 2, column: 4 }
-- | ]
-- | ```
-- |
-- | #### Example
-- |
-- | Find groups of balanced nested parentheses. This pattern is an example of
-- | a “context-free” grammar, a pattern that
-- | [can't be expressed by a regular expression](https://stackoverflow.com/questions/1732348/regex-match-open-tags-except-xhtml-self-contained-tags/1732454#1732454).
-- | We can express the pattern with a recursive parser.
-- |
-- | ```purescript
-- | balancedParens :: Parser String Unit
-- | balancedParens = do
-- |   void $ char '('
-- |   void $ manyTill (balancedParens <|> void anyCodePoint) (char ')')
-- |
-- | rmap fst <$> splitCap "((🌼)) (()())" (match balancedParens)
-- | ```
-- |
-- | Result:
-- |
-- | ```purescript
-- | [Right "((🌼))", Left " ", Right "(()())"]
-- | ```
splitCap
  :: forall a
   . String
  -> Parser String a
  -> NonEmptyList (Either String a)
splitCap input sep = unwrap $ splitCapT input sep

-- | Monad transformer version of `streamEdit`. The `sep` parser and the
-- | `editor` function will both run in the monad context.
-- |
-- | #### Example
-- |
-- | Find an environment variable in curly braces and replace it with its value
-- | from the environment.
-- | We can read from the environment because `streamEditT` is running the
-- | `editor` function in `Effect`.
-- |
-- | ```purescript
-- | pattern = string "{" *> anyTill (string "}")
-- | editor  = fst >>> lookupEnv >=> fromMaybe "" >>> pure
-- | streamEditT "◀ {HOME} ▶" pattern editor
-- | ```
-- |
-- | Result:
-- |
-- | ```purescript
-- | "◀ /home/jbrock ▶"
-- | ```
-- |
-- | [![Perl Problems](https://imgs.xkcd.com/comics/perl_problems.png)](https://xkcd.com/1171/)
streamEditT
  :: forall m a
   . (Monad m)
  => (MonadRec m)
  => String
  -> ParserT String m a
  -> (a -> m String)
  -> m String
streamEditT input sep editor = do
  runParserT input (Tuple <$> (splitCapCombinator sep) <*> rest) >>= case _ of
    Left _ -> pure input
    Right (Tuple { carry, rlist, arraySize } remain) -> do
      let
        term = maybe remain (\cp -> CodePoint.singleton cp <> remain) carry

      arr :: STArray Global (Nullable String) <- doST
        if String.null term then
          Array.ST.unsafeThaw $ Array.replicate arraySize null
        else
          do
            arr <- Array.ST.unsafeThaw $ Array.replicate (arraySize + 1) null
            unsafePartial $ Array.ST.Partial.poke arraySize (notNull term) arr
            pure arr

      let
        accum
          :: { index :: Int, rlist' :: List (Tuple String a) }
          -> m (Step { index :: Int, rlist' :: List (Tuple String a) } Unit)
        accum { index, rlist' } = case uncons rlist' of
          Nothing -> pure $ Done unit
          Just { head: Tuple unmatched matched, tail } -> do
            edited <- editor matched
            doST $ unsafePartial $ Array.ST.Partial.poke index (notNull edited) arr
            if String.null unmatched then
              do
                pure $ Loop { index: index - 1, rlist': tail }
            else
              do
                doST $ unsafePartial $ Array.ST.Partial.poke (index - 1) (notNull unmatched) arr
                pure $ Loop { index: index - 2, rlist': tail }

      -- un-reverse the list into the mutable Array
      tailRecM accum { index: arraySize - 1, rlist': rlist }

      -- All of this prior struggle is so that we can finally stich together
      -- the whole result with a single call to joinWith, which we believe
      -- must be the fastest way to fold a String.
      joinWith "" <$> unsafeCoerce <$> doST (Array.ST.unsafeFreeze arr)
  where
  -- Sequence ST operations in some other monad. What could possibly go wrong?
  doST :: forall b. ST Global b -> m b
  doST = pure <<< unsafePerformEffect <<< toEffect

-- |
-- | #### Stream editor
-- |
-- | Also known as “find-and-replace”, or “match-and-substitute”. Find all
-- | of the leftmost non-overlapping sections of the input string which match
-- | the pattern parser `sep`, and
-- | replace them with the result of the `editor` function.
-- |
-- | This function can be used instead of
-- | [Data.String.replaceAll](https://pursuit.purescript.org/packages/purescript-strings/docs/Data.String#v:replaceAll)
-- | or
-- | [Data.String.Regex.replace'](https://pursuit.purescript.org/packages/purescript-strings/docs/Data.String.Regex#v:replace').
-- |
-- | #### Access the matched section of text in the `editor`
-- |
-- | If you want access to the matched string in the `editor` function,
-- | then combine the pattern parser `sep`
-- | with `match`. This will effectively change
-- | the type of the `editor` function to `(String /\ a) -> String`.
-- |
-- | This allows us to write an `editor` function which can choose to not
-- | edit the match and just leave it as it is. If the `editor` function
-- | returns the first item in the tuple, then `streamEdit` will not change
-- | the matched string.
-- |
-- | So, for all `sep`:
-- |
-- | ```purescript
-- | streamEdit input (match sep) fst == input
-- | ```
-- |
-- | #### Example
-- |
-- | Find and uppercase the `"needle"` pattern.
-- |
-- | ```purescript
-- | streamEdit "hay needle hay" (string "needle") toUpper
-- | ```
-- |
-- | Result:
-- |
-- | ```purescript
-- | "hay NEEDLE hay"
-- | ```
streamEdit
  :: forall a
   . String
  -> Parser String a
  -> (a -> String)
  -> String
streamEdit input sep editor = unwrap $ streamEditT input sep (wrap <<< editor)
