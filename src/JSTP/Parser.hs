module JSTP.Parser(readJSRS
                  ,readJValue
                  ) where

import JSTP.ParserSettings(validateFieldName
                          ,dropWhileWhiteSpace
                          ,nameValSeps
                          ,fieldSeps
                          ,whiteSpaceChars
                          ,slashCombos
                          ,valueSeps
                          )

import Data.List(isPrefixOf)
import Data.Maybe(fromJust)
import Data.Char(isDigit)
import qualified Data.Map as M
import Control.DeepSeq

import JSTP.JSRS
import JSTP.Errors

readJSRS :: String -> WithError JObject
readJSRS = fmap fst . readJSRSRest

readJSRSRest :: String -> WithError (JObject, String)
readJSRSRest str = case str' of
        [] -> Left "JSRS parse error: empty string"
        '{':inner -> readFields inner
        _ -> Left "Must be open figure bracket"
    where str' = dropWhileWhiteSpace str

readFields :: String -> WithError (JObject, String)
readFields str = case str' of
        '}':rest -> Right (fromList [], rest)
        _        -> do
            (field, str'') <- readField str'
            case dropWhileWhiteSpace str'' of
                '}':rest -> Right (fromList [field], rest)
                ch:rest  -> if elem ch fieldSeps
                            then fmap (mapFst (insertField field).seqId) 
                                      (readFields rest)
                            else Left "Wrong field separator"
    where str' = dropWhileWhiteSpace str


readJValue :: String -> WithError JValue
readJValue str = fmap fst (readJValueRest str)

readJValueRest :: String -> WithError (JValue, String)
readJValueRest str2
    | getToken "true" /= Nothing = Right (JBool True, fromJust (getToken "true"))
    | getToken "false" /= Nothing = Right (JBool False, fromJust (getToken "false"))
    | numberStr /= [] = Right (readNumber numberStr, drop (length numberStr) str)
    | otherwise = case str of
        ('\'':rest) -> fmap (mapFst JString) (readString '\'' rest)
        ('"':rest) -> fmap (mapFst JString) (readString '"' rest)
        ('{':rest)  -> fmap (mapFst JObj)    (readJSRSRest str)  
        ('[':rest)  -> fmap (mapFst JArray)  (readJValues rest)
        _ -> Left "Unknown data type"

  where str = dropWhileWhiteSpace str2
        getToken token = if token `isPrefixOf` str
          then Just (drop (length token) str)
          else Nothing
        numberStr = getNumber str
        genRead = if elem '.' numberStr then JDouble . read else JInt . read
        readNumber = JNumber . genRead 

        getNumber [] = []
        getNumber (x:xs) =
          if isDigit x || x == '-'
          then x:(getNumber' False xs)
          else []

        getNumber' wasDot [] = []
        getNumber' wasDot (x:str) = 
            if isDigit x
            then x:(getNumber' wasDot str)
            else if x == '.'
                 then if wasDot 
                      then [] 
                      else x:(getNumber' True str)
                 else []

readJValues :: String -> WithError ([JValue], String)
readJValues str = case str' of
        ']':rest -> Right ([], rest)
        _   -> do
            (value, str') <- readJValueRest str
            case dropWhileWhiteSpace str' of
                ']':rest -> Right ([value], rest)
                ch:rest -> if elem ch valueSeps
                           then fmap (mapFst (value:)) (readJValues rest)
                           else Left "Wrong value separator"
                _ -> Left "No close bracket"
    where str' = dropWhileWhiteSpace str

readString :: Char -> String -> WithError (String, String)
readString quote (ch:str)
  | ch == quote = Right ("", str)
  | ch == '\\' = readString quote str
  | otherwise = fmap (mapFst (ch:)) (readString quote str)
readString _ [] = Left "There is not close quote for string literal"

dropSeparator :: [Char] -> String -> WithError String
dropSeparator separators str = case str' of 
        (x:rest) -> if elem x separators
                    then Right rest
                    else Left "Wrong separator"
    where str' = dropWhileWhiteSpace str

dropFieldSeparator :: String -> WithError String
dropFieldSeparator = dropSeparator fieldSeps

dropNameValSeparator :: String -> WithError String
dropNameValSeparator = dropSeparator nameValSeps 

readField :: String -> WithError (JField, String)
readField str = do
        (fieldName, rest) <- readFieldName str' 
        rest' <- dropNameValSeparator rest
        (fieldVal, rest') <- readFieldValue rest'
        return ((fieldName, fieldVal), rest')
    where str' = dropWhileWhiteSpace str


readFieldName :: String -> WithError (String, String)
readFieldName str = if validateFieldName fieldName
                  then Right (fieldName, rest)
                  else Left ("Fieldname \"" ++ fieldName++"\" is invalid")
    where delChars = nameValSeps++whiteSpaceChars
          fieldName = takeWhile (`notElem` delChars) str
          rest = dropWhile (`notElem` delChars) str

readFieldValue :: String -> Either String (JValue, String)
readFieldValue = readJValueRest . dropWhileWhiteSpace

mapFst :: (a -> c) -> (a, b) -> (c, b)
mapFst fn (a, b) = (fn a, b)

seqId :: (NFData a) => a -> a
seqId x = deepseq x x 