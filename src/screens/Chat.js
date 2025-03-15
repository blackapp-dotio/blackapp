import React, { useState, useEffect } from 'react';
import { View, Text, TouchableOpacity, Alert } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import { ref, onValue } from '@react-native-firebase/database';
import { auth } from '../firebaseConfig';
import ChatList from './ChatList';
import ChatConversation from './ChatConversation';
import GroupChat from './GroupChat';
import SendAGMoney from './SendAGMoney';
import styles from '../styles/ChatStyles'; // Import styles

const Chat = ({ navigation }) => {
    const [unreadMessages, setUnreadMessages] = useState(0);

    useEffect(() => {
        const user = auth().currentUser;
        if (user) {
            const messagesRef = ref(database, 'messages');
            onValue(messagesRef, (snapshot) => {
                const messagesData = snapshot.val();
                let count = 0;
                Object.keys(messagesData || {}).forEach(key => {
                    const message = messagesData[key];
                    if (message.recipientId === user.uid && !message.isRead) {
                        count++;
                    }
                });
                setUnreadMessages(count);
            });
        }
    }, []);

    return (
        <View style={styles.chatContainer}>
            <View style={styles.tabs}>
                <TouchableOpacity
                    onPress={() => navigation.navigate('ActiveChats')}
                    style={styles.tabButton}>
                    <Text style={styles.tabText}>Active Chats</Text>
                </TouchableOpacity>
                <TouchableOpacity
                    onPress={() => navigation.navigate('GroupChat')}
                    style={styles.tabButton}>
                    <Text style={styles.tabText}>Group Chat</Text>
                </TouchableOpacity>
                <TouchableOpacity
                    onPress={() => navigation.navigate('SendMoney')}
                    style={styles.tabButton}>
                    <Text style={styles.tabText}>Send AGMoney</Text>
                </TouchableOpacity>
            </View>

            {/* Content will be rendered via Navigation */}
        </View>
    );
};

export default Chat;
