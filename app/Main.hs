module Main where
import Network.Socket hiding (Broadcast)
import System.IO
import Control.Monad
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.Async
import Data.Map as Map
import Data.Char
import Data.Hashable
import Data.List.Split

data Message = Command [[String]] | Error String String | Broadcast String String String | Response String

data Client = Client { clientName :: String, clientChan :: TChan Message, clientHdl :: Handle, clientID :: Int }
data Chatroom = Chatroom { roomName :: String, roomRef:: Int, clients :: TVar (Map Int Client) }

type Chatrooms = TVar (Map Int Chatroom)

newClient :: Int -> String -> Handle -> IO Client
newClient num name hdl = do
  chan <- newTChanIO
  return Client { clientName = name, clientChan = chan, clientHdl = hdl, clientID = num }

newChatroom :: String -> Client -> STM Chatroom
newChatroom name client = do
  let d = Map.insert (clientID client) client Map.empty
  c <- newTVar d
  return Chatroom { roomName = name, roomRef = (hash name),clients = c }

fetchChatroom :: Int -> Chatrooms -> STM (Maybe Chatroom)
fetchChatroom roomRef chatrooms = do
  chatmap <- readTVar chatrooms
  let c = Map.lookup roomRef chatmap
  case c of 
    Nothing -> return Nothing
    Just c -> return (Just c)

broadcastMessage :: Message -> Client -> Int -> Chatrooms -> IO ()
broadcastMessage msg client roomRef chatrooms = atomically $ do
  c <- fetchChatroom roomRef chatrooms
  case c of
    Nothing -> sendMessage client $ Error "200" "This chatroom does not exist"
    Just room -> do
      roomMap <- readTVar (clients room)
      mapM_ (\c -> sendMessage c msg) (Map.elems roomMap)

sendMessage :: Client -> Message -> STM ()
sendMessage client msg = writeTChan (clientChan client) msg
 
handleMessage :: Chatrooms -> Client -> Message -> IO Bool
handleMessage chatrooms client message = do
  case message of
    Response msg               -> display $ msg ++ "\n"
    Broadcast roomRef name msg -> display ("CHAT:" ++ roomRef ++ "\nCLIENT_NAME:" ++ name  ++ "\nMESSAGE:" ++ msg)
    Error code msg             -> display ("ERROR_CODE:" ++ code ++ "\nERROR_DESCRIPTION:" ++ msg)
    Command msg                ->
      case msg of
        [["CHAT:",roomRef],["JOIN_ID:",id],["CLIENT_NAME:",name],("MESSAGE:":msg)]       -> do
          broadcastMessage (Broadcast roomRef (clientName client) (unwords msg)) client (read roomRef :: Int) chatrooms       
          return True
        [["JOIN_CHATROOM:",roomName],["CLIENT_IP:","0"],["PORT:","0"],["CLIENT_NAME:",name]] -> do
          addClient client roomName chatrooms
          broadcastMessage (Broadcast (show $ hash roomName) (clientName client) "has joined the chat." ) client (hash roomName) chatrooms  
          print ("client["++ name ++"] added to room: " ++ roomName)
          return True
        [["LEAVE_CHATROOM:",roomRef],["JOIN_ID:",id],["CLIENT_NAME:",name]]                  -> do
          unless (noMatch client id) $ do
            left <- removeClient client (read roomRef :: Int) chatrooms
            when left $ do
              broadcastMessage (Broadcast roomRef (clientName client) "Has left the chatroom.") client (read roomRef :: Int) chatrooms
              print ("client["++ name ++"] has left chatroom: " ++ roomRef)
          return True
        [["DISCONNECT:","0"],["PORT:","0"],["CLIENT_NAME:",name]]                            -> do
          print (name ++ " disconnected.")
          return False
        _                                                                                    -> atomically $ do
          sendMessage client $ Error "100" "Unknown command or inconsistent information provided."
          return True
    where
     display x = do hPutStrLn (clientHdl client) ("\n" ++ x); return True

noMatch :: Client -> String -> Bool
noMatch client id 
  | id == ( show $ clientID client) = False
  | otherwise = True

removeClient :: Client -> Int -> Chatrooms -> IO Bool
removeClient client roomRef chatrooms = atomically $ do
  c <- fetchChatroom roomRef chatrooms
  case c of 
    Nothing -> return False
    Just room -> do
      modifyTVar' (clients room) $ Map.delete (clientID client)
      sendMessage client $ Response ("LEFT_CHATROOM:" ++ show roomRef  ++ "\nJOIN_ID:" ++ (show $ clientID client))
      return True    

addClient :: Client -> String -> Chatrooms -> IO ()
addClient client roomName chatrooms = atomically $ do
  chatmap <- readTVar chatrooms
  let c = Map.lookup (hash roomName) chatmap
  case c of 
    Nothing -> do
      chat <- newChatroom roomName client
      let newChatmap = Map.insert (roomRef chat) chat chatmap
      writeTVar chatrooms newChatmap
    (Just room) -> do
      roomMap <- readTVar (clients room)
      let newRoom = Map.insert (clientID client) client roomMap
      writeTVar (clients room) newRoom
  sendMessage client $ Response ("JOINED_CHATROOM:" ++ roomName ++ "\nSERVER_IP:\nPORT:\nROOM_REF:"++ (show $ hash roomName) ++ "\nJOIN_ID:" ++ (show $ clientID client))

runClient :: Chatrooms -> Client -> IO ()
runClient chatrooms client = do
  race receiver sender
  return ()
  where
   sender = forever $ do
     msg <- hGetLines (clientHdl client) ""
     atomically $ do sendMessage client $ Command msg

   receiver = join $ atomically $ do
     msg <- readTChan (clientChan client)
     return $ do
       continue <- handleMessage chatrooms client msg
       when continue $ receiver

buildClient :: Chatrooms -> Int -> Handle -> IO ()
buildClient chatrooms num hdl = do
  loop
  hClose hdl
  where 
   loop = do
     msg <- hGetLines hdl ""
     case msg of
       [["JOIN_CHATROOM:",roomName],["CLIENT_IP:","0"],["PORT:","0"],["CLIENT_NAME:",clientName]] -> do
         let roomRef = hash roomName
         client <- newClient num clientName hdl
         addClient client roomName chatrooms
         broadcastMessage (Broadcast (show $ roomRef) clientName "has joined the chat." ) client roomRef chatrooms  
         print ("New client["++ clientName ++"]["++ show num ++"] added to room: " ++ roomName)
         runClient chatrooms client
       _                    -> hPutStrLn hdl "ERROR_CODE:100\nERROR_DESCRIPTION:Please join a chatroom before continuing." >> loop

getClients :: Chatrooms -> Socket -> Int -> IO ()
getClients chatrooms sock num = do
  conn <- accept sock
  hdl <- socketToHandle (fst conn) ReadWriteMode
  hSetBuffering hdl NoBuffering
  forkIO $ buildClient chatrooms num hdl
  getClients chatrooms sock (num + 1)


hGetLines :: Handle -> String -> IO [[String]]
hGetLines hdl acc = do
  line <- hGetLine hdl
  more <- hReady hdl
  if more then hGetLines hdl $ line ++ acc
  else do
    return $ Prelude.map words $ splitOn "\\n" $ line ++ acc

main :: IO ()
main = do
  sock <- socket AF_INET Stream 0
  setSocketOption sock ReuseAddr 1
  bind sock $ SockAddrInet 5555 iNADDR_ANY
  listen sock 5
  chatrooms <- atomically $ newTVar Map.empty
  print "Server started... Listening on port 5555"
  getClients chatrooms sock 1

