import React, { useState } from 'react';
import { View, Text, TextInput, TouchableOpacity, Modal, Alert } from 'react-native';
import { ref, push } from 'firebase/database';
import { database } from '../firebase';
import styles from '../styles/SupportStyles';

const Support = () => {
    const [message, setMessage] = useState('');
    const [isFormOpen, setIsFormOpen] = useState(false);
    const [isSent, setIsSent] = useState(false);

    const supportAccountId = 'TrISZb4hOgUyonJoSwlpwGE3PxF2'; // Support account unique ID.

    const handleFormToggle = () => {
        setIsFormOpen(!isFormOpen);
        setIsSent(false);
        setMessage('');
    };

    const handleSubmit = async () => {
        if (!message.trim()) {
            Alert.alert('Error', 'Please enter a message.');
            return;
        }

        try {
            const chatRef = ref(database, `chats/${supportAccountId}`);
            await push(chatRef, {
                message,
                sender: 'Anonymous User',
                timestamp: Date.now(),
            });

            setIsSent(true);
            setMessage('');
            Alert.alert('Success', 'Your message has been sent to support!');
        } catch (error) {
            console.error('Error sending support message:', error);
            Alert.alert('Error', 'Failed to send your message. Please try again.');
        }
    };

    return (
        <View style={styles.container}>
            {/* Support Button */}
            <TouchableOpacity style={styles.supportButton} onPress={handleFormToggle}>
                <Text style={styles.questionMark}>?</Text>
            </TouchableOpacity>

            {/* Support Modal */}
            <Modal visible={isFormOpen} animationType="slide" transparent>
                <View style={styles.modalContainer}>
                    <View style={styles.supportBox}>
                        <Text style={styles.header}>Support</Text>
                        <Text style={styles.description}>If you need help, send us a message below:</Text>
                        
                        <TextInput
                            style={styles.textInput}
                            placeholder="Type your message here..."
                            placeholderTextColor="#bbb"
                            value={message}
                            onChangeText={setMessage}
                            multiline
                        />

                        <TouchableOpacity style={styles.sendButton} onPress={handleSubmit}>
                            <Text style={styles.sendButtonText}>Send Message</Text>
                        </TouchableOpacity>

                        <TouchableOpacity style={styles.closeButton} onPress={handleFormToggle}>
                            <Text style={styles.closeButtonText}>Close</Text>
                        </TouchableOpacity>
                    </View>
                </View>
            </Modal>
        </View>
    );
};

export default Support;
