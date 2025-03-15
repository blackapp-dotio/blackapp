import React, { useState, useEffect } from 'react';
import { View, Text, TextInput, TouchableOpacity, FlatList, Alert } from 'react-native';
import { ref, onValue, push, update, remove } from '@react-native-firebase/database';
import { auth } from '../firebaseConfig';
import { Picker } from 'emoji-mart-native'; // React Native Emoji Picker
import Ionicons from 'react-native-vector-icons/Ionicons';
import styles from '../styles/ChatConversationStyles'; // Import styles

const ChatConversation = ({ route }) => {
    const { userId } = route.params; // Get userId from navigation route
    const [messages, setMessages] = useState([]);
    const [newMessage, setNewMessage] = useState('');
    const [showEmojiPicker, setShowEmojiPicker] = useState(false);

    useEffect(() => {
        const user = auth().currentUser;
        if (!user) return;

        const messagesRef = ref(database, 'messages');

        const unsubscribe = onValue(messagesRef, (snapshot) => {
            const messagesData = snapshot.val();
            const messagesList = Object.keys(messagesData || {}).map(key => ({
                id: key,
                ...messagesData[key],
            }));

            const userMessages = messagesList.filter(msg => 
                (msg.senderId === user.uid && msg.recipientId === userId) ||
                (msg.senderId === userId && msg.recipientId === user.uid)
            );

            setMessages(userMessages);
            markMessagesAsRead(userMessages);
        });

        return () => unsubscribe();
    }, [userId]);

    // Mark messages as read
    const markMessagesAsRead = (messages) => {
        const user = auth().currentUser;

        const unreadMessages = messages.filter(msg => msg.recipientId === user.uid && !msg.isRead);

        const updates = {};
        unreadMessages.forEach((msg) => {
            updates[`/messages/${msg.id}/isRead`] = true;
        });

        if (Object.keys(updates).length > 0) {
            update(ref(database), updates);
        }
    };

    // Send message
    const sendMessage = async () => {
        if (newMessage.trim() === '') {
            Alert.alert("Message cannot be empty.");
            return;
        }

        const user = auth().currentUser;

        const message = {
            text: newMessage,
            senderId: user.uid,
            recipientId: userId,
            timestamp: new Date().toISOString(),
            isRead: false,
        };

        try {
            await push(ref(database, 'messages'), message);
            setNewMessage('');
        } catch (error) {
            console.error("Error sending message:", error);
        }
    };

    // Handle emoji selection
    const handleEmojiSelect = (emoji) => {
        setNewMessage(prevMessage => prevMessage + emoji.native);
        setShowEmojiPicker(false);
    };

    // Delete individual message
    const deleteMessage = (messageId) => {
        Alert.alert(
            "Delete Message",
            "Are you sure you want to delete this message?",
            [
                { text: "Cancel", style: "cancel" },
                { text: "Delete", onPress: () => remove(ref(database, `messages/${messageId}`)) }
            ]
        );
    };

    // Delete entire chat
    const deleteChat = () => {
        Alert.alert(
            "Delete Chat",
            "Are you sure you want to delete the entire conversation?",
            [
                { text: "Cancel", style: "cancel" },
                { text: "Delete", onPress: () => {
                    const user = auth().currentUser;
                    const messagesRef = ref(database, 'messages');

                    onValue(messagesRef, (snapshot) => {
                        const messagesData = snapshot.val();
                        const userMessages = Object.keys(messagesData || {}).filter(key => {
                            const msg = messagesData[key];
                            return (msg.senderId === user.uid && msg.recipientId === userId) || 
                                   (msg.senderId === userId && msg.recipientId === user.uid);
                        });

                        userMessages.forEach((messageId) => {
                            remove(ref(database, `messages/${messageId}`));
                        });
                    });
                }}
            ]
        );
    };

    return (
        <View style={styles.container}>
            <FlatList
                data={messages}
                keyExtractor={(item) => item.id}
                renderItem={({ item }) => (
                    <View style={[styles.message, item.senderId === auth().currentUser.uid ? styles.sent : styles.received]}>
                        <Text style={styles.messageText}>{item.text}</Text>
                        <Text style={styles.timestamp}>{new Date(item.timestamp).toLocaleString()}</Text>
                        {item.senderId === auth().currentUser.uid && (
                            <TouchableOpacity onPress={() => deleteMessage(item.id)} style={styles.deleteIcon}>
                                <Ionicons name="trash-outline" size={20} color="red" />
                            </TouchableOpacity>
                        )}
                    </View>
                )}
            />

            {/* Message Input */}
            <View style={styles.inputContainer}>
                {showEmojiPicker && <Picker onSelect={handleEmojiSelect} />}
                
                <TextInput
                    style={styles.input}
                    value={newMessage}
                    onChangeText={setNewMessage}
                    placeholder="Type a message"
                    placeholderTextColor="#bbb"
                />

                <TouchableOpacity onPress={sendMessage} style={styles.sendButton}>
                    <Ionicons name="send" size={24} color="white" />
                </TouchableOpacity>

                <TouchableOpacity onPress={() => setShowEmojiPicker(!showEmojiPicker)} style={styles.emojiButton}>
                    <Text style={styles.emojiText}>😊</Text>
                </TouchableOpacity>

                <TouchableOpacity onPress={deleteChat} style={styles.deleteChatButton}>
                    <Ionicons name="trash-bin" size={24} color="red" />
                </TouchableOpacity>
            </View>
        </View>
    );
};

export default ChatConversation;
