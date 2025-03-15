import React, { useState, useEffect } from 'react';
import {
    View,
    Text,
    TextInput,
    TouchableOpacity,
    FlatList,
    ScrollView,
    Alert,
} from 'react-native';
import { ref, onValue, push, update, remove } from '@react-native-firebase/database';
import { auth } from '../firebaseConfig';
import { Picker } from 'emoji-mart-native'; // React Native Emoji Picker
import Ionicons from 'react-native-vector-icons/Ionicons';
import styles from '../styles/GroupChatStyles'; // Import styles

const GroupChat = () => {
    const [groups, setGroups] = useState([]);
    const [selectedGroup, setSelectedGroup] = useState(null);
    const [newGroupName, setNewGroupName] = useState('');
    const [messages, setMessages] = useState([]);
    const [newMessage, setNewMessage] = useState('');
    const [showEmojiPicker, setShowEmojiPicker] = useState(false);
    const [groupMembers, setGroupMembers] = useState([]);
    const [users, setUsers] = useState([]);
    const [selectedUser, setSelectedUser] = useState('');
    const [filteredUsers, setFilteredUsers] = useState([]);

    useEffect(() => {
        const groupsRef = ref(database, 'groupChats');
        const usersRef = ref(database, 'users');

        const unsubscribeGroups = onValue(groupsRef, (snapshot) => {
            const data = snapshot.val();
            setGroups(data ? Object.keys(data).map(key => ({ id: key, ...data[key] })) : []);
        });

        const unsubscribeUsers = onValue(usersRef, (snapshot) => {
            const usersData = snapshot.val();
            if (usersData) {
                const userList = Object.keys(usersData).map(key => ({
                    id: key,
                    displayName: usersData[key].displayName || 'Unknown User',
                }));
                setUsers(userList);
            }
        });

        return () => {
            unsubscribeGroups();
            unsubscribeUsers();
        };
    }, []);

    useEffect(() => {
        if (!selectedGroup) return;

        const messagesRef = ref(database, `groupMessages/${selectedGroup.id}`);
        const membersRef = ref(database, `groupChats/${selectedGroup.id}/members`);

        const unsubscribeMessages = onValue(messagesRef, (snapshot) => {
            const data = snapshot.val();
            setMessages(data ? Object.keys(data).map(key => ({ id: key, ...data[key] })) : []);
        });

        const unsubscribeMembers = onValue(membersRef, (snapshot) => {
            const data = snapshot.val();
            if (data) {
                setGroupMembers(Object.keys(data).map(userId => ({
                    id: userId,
                    displayName: data[userId].displayName || 'Unknown User',
                })));
            }
        });

        return () => {
            unsubscribeMessages();
            unsubscribeMembers();
        };
    }, [selectedGroup]);

    const createGroup = async () => {
        if (newGroupName.trim() === '') {
            Alert.alert('Group name is required.');
            return;
        }

        const user = auth().currentUser;
        const groupRef = push(ref(database, 'groupChats'));

        await update(groupRef, {
            id: groupRef.key,
            name: newGroupName,
            createdBy: user.uid,
            createdAt: new Date().toISOString(),
            members: {
                [user.uid]: { displayName: user.displayName || 'Unknown User' },
            },
        });

        setNewGroupName('');
    };

    const joinGroup = async (groupId) => {
        const user = auth().currentUser;
        const groupRef = ref(database, `groupChats/${groupId}/members/${user.uid}`);

        await update(groupRef, {
            displayName: user.displayName || 'Unknown User',
            joinedAt: new Date().toISOString(),
        });

        setSelectedGroup(groups.find(group => group.id === groupId));
    };

    const sendMessage = async () => {
        if (newMessage.trim() === '' || !selectedGroup) return;

        const user = auth().currentUser;
        const messageRef = push(ref(database, `groupMessages/${selectedGroup.id}`));

        await update(messageRef, {
            id: messageRef.key,
            text: newMessage,
            senderId: user.uid,
            senderName: user.displayName || 'Unknown User',
            timestamp: new Date().toISOString(),
        });

        setNewMessage('');
    };

    const deleteMessage = async (messageId) => {
        await remove(ref(database, `groupMessages/${selectedGroup.id}/${messageId}`));
    };

    return (
        <View style={styles.container}>
            <View style={styles.sidebar}>
                <Text style={styles.title}>Group Chats</Text>
                <View style={styles.createGroup}>
                    <TextInput
                        style={styles.input}
                        placeholder="New group..."
                        value={newGroupName}
                        onChangeText={setNewGroupName}
                        placeholderTextColor="#bbb"
                    />
                    <TouchableOpacity onPress={createGroup} style={styles.createButton}>
                        <Ionicons name="add" size={24} color="white" />
                    </TouchableOpacity>
                </View>

                <FlatList
                    data={groups}
                    keyExtractor={(item) => item.id}
                    renderItem={({ item }) => (
                        <TouchableOpacity
                            style={[styles.groupItem, selectedGroup?.id === item.id && styles.activeGroup]}
                            onPress={() => joinGroup(item.id)}
                        >
                            <Text style={styles.groupName}>{item.name}</Text>
                        </TouchableOpacity>
                    )}
                />
            </View>

            <View style={styles.chatWindow}>
                {selectedGroup ? (
                    <>
                        <Text style={styles.groupTitle}>{selectedGroup.name}</Text>
                        <ScrollView style={styles.messages}>
                            {messages.map((msg) => (
                                <View key={msg.id} style={[styles.message, msg.senderId === auth().currentUser.uid ? styles.sent : styles.received]}>
                                    <Text style={styles.messageText}>
                                        <Text style={styles.sender}>{msg.senderName}: </Text>{msg.text}
                                    </Text>
                                    <Text style={styles.timestamp}>{new Date(msg.timestamp).toLocaleTimeString()}</Text>
                                </View>
                            ))}
                        </ScrollView>

                        <View style={styles.inputContainer}>
                            {showEmojiPicker && <Picker onSelect={(emoji) => setNewMessage(prev => prev + emoji.native)} />}
                            <TextInput
                                style={styles.input}
                                value={newMessage}
                                onChangeText={setNewMessage}
                                placeholder="Type a message..."
                                placeholderTextColor="#bbb"
                            />
                            <TouchableOpacity onPress={sendMessage} style={styles.sendButton}>
                                <Ionicons name="send" size={24} color="white" />
                            </TouchableOpacity>
                        </View>
                    </>
                ) : (
                    <Text style={styles.placeholderText}>Select a group to start chatting.</Text>
                )}
            </View>
        </View>
    );
};

export default GroupChat;
