import React, { useState, useEffect } from 'react';
import { View, Text, TextInput, FlatList, TouchableOpacity } from 'react-native';
import { ref, onValue, get, update } from '@react-native-firebase/database';
import { auth } from '../firebaseConfig';
import ChatConversation from './ChatConversation';
import GroupChat from './GroupChat';
import SendAGMoney from './SendAGMoney';
import styles from '../styles/ChatListStyles'; // Import styles

const ChatList = ({ navigation }) => {
    const [activeTab, setActiveTab] = useState('activeChats');
    const [selectedChat, setSelectedChat] = useState(null);
    const [searchQuery, setSearchQuery] = useState('');
    const [filteredUsers, setFilteredUsers] = useState([]);
    const [chats, setChats] = useState([]);
    const [unreadCount, setUnreadCount] = useState(0);

    useEffect(() => {
        const user = auth().currentUser;
        if (user) {
            const messagesRef = ref(database, 'messages');
            const unreadRef = ref(database, `unread_messages/${user.uid}`);

            // Listen for unread message count
            onValue(unreadRef, (snapshot) => {
                setUnreadCount(snapshot.val() || 0);
            });

            // Listen for new messages
            onValue(messagesRef, async (snapshot) => {
                const messagesData = snapshot.val();
                const activeChats = [];

                for (const key in messagesData) {
                    const message = messagesData[key];
                    const chatPartnerId = message.senderId === user.uid ? message.recipientId : message.senderId;
                    const isFollowing = await isUserFollowing(chatPartnerId);

                    if (isFollowing) {
                        const userRef = ref(database, `users/${chatPartnerId}`);
                        const userSnapshot = await get(userRef);
                        const chatPartnerDisplayName = userSnapshot.exists() ? userSnapshot.val().displayName : 'Unknown User';

                        const existingChat = activeChats.find(chat => chat.userId === chatPartnerId);
                        const isUnread = message.recipientId === user.uid && !message.isRead;

                        if (!existingChat) {
                            activeChats.push({
                                userId: chatPartnerId,
                                displayName: chatPartnerDisplayName,
                                lastMessage: message.text,
                                timestamp: message.timestamp,
                                isUnread,
                                unreadCount: isUnread ? 1 : 0,
                            });
                        } else {
                            existingChat.unreadCount += isUnread ? 1 : 0;
                            if (message.timestamp > existingChat.timestamp) {
                                existingChat.lastMessage = message.text;
                                existingChat.timestamp = message.timestamp;
                            }
                        }
                    }
                }

                setChats(activeChats.sort((a, b) => b.timestamp - a.timestamp));
                setFilteredUsers(activeChats);
            });
        }
    }, []);

    // Check if the user follows the chat partner
    const isUserFollowing = async (chatPartnerId) => {
        const followingRef = ref(database, `following/${auth().currentUser.uid}`);
        const followingSnapshot = await get(followingRef);
        return followingSnapshot.val()?.[chatPartnerId] !== undefined;
    };

    const handleSearchChange = (query) => {
        setSearchQuery(query);
        setFilteredUsers(chats.filter(chat => chat.displayName.toLowerCase().includes(query.toLowerCase())));
    };

    const startConversation = (userId) => {
        const chat = chats.find(c => c.userId === userId);
        if (chat) {
            setSelectedChat(chat);
            navigation.navigate('ChatConversation', { userId });

            if (chat.unreadCount > 0) {
                update(ref(database, `unread_messages/${auth().currentUser.uid}`), { count: 0 });
                setChats(prevChats =>
                    prevChats.map(c => (c.userId === userId ? { ...c, unreadCount: 0 } : c))
                );
            }
        }
    };

    return (
        <View style={styles.container}>
            {/* Tab Navigation */}
            <View style={styles.tabs}>
                <TouchableOpacity style={styles.tabButton} onPress={() => setActiveTab('activeChats')}>
                    <Text style={styles.tabText}>
                        Active Chats {unreadCount > 0 ? `(${unreadCount})` : ''}
                    </Text>
                </TouchableOpacity>
                <TouchableOpacity style={styles.tabButton} onPress={() => setActiveTab('groupChats')}>
                    <Text style={styles.tabText}>Group Chats</Text>
                </TouchableOpacity>
                <TouchableOpacity style={styles.tabButton} onPress={() => setActiveTab('sendAGMoney')}>
                    <Text style={styles.tabText}>Send AGMoney</Text>
                </TouchableOpacity>
            </View>

            {/* Search Bar */}
            {activeTab === 'activeChats' && (
                <TextInput
                    style={styles.searchInput}
                    placeholder="Search users..."
                    placeholderTextColor="#ccc"
                    value={searchQuery}
                    onChangeText={handleSearchChange}
                />
            )}

            {/* Chat List */}
            {activeTab === 'activeChats' && (
                <FlatList
                    data={filteredUsers}
                    keyExtractor={(item) => item.userId}
                    renderItem={({ item }) => (
                        <TouchableOpacity style={styles.chatItem} onPress={() => startConversation(item.userId)}>
                            <Text style={styles.chatName}>{item.displayName}</Text>
                            <Text style={styles.lastMessage}>{item.lastMessage}</Text>
                            {item.unreadCount > 0 && <Text style={styles.unreadBadge}>({item.unreadCount})</Text>}
                        </TouchableOpacity>
                    )}
                />
            )}

            {activeTab === 'groupChats' && <GroupChat />}
            {activeTab === 'sendAGMoney' && <SendAGMoney />}
        </View>
    );
};

export default ChatList;
