import React, { useState, useEffect } from 'react';
import {
    View,
    Text,
    TextInput,
    TouchableOpacity,
    Alert,
    FlatList,
} from 'react-native';
import { ref, onValue, update, get } from '@react-native-firebase/database';
import { auth } from '../firebaseConfig';
import { calculatePlatformFee } from '../utils/feeUtils';
import styles from '../styles/SendAGMoneyStyles';

const SendAGMoney = () => {
    const [users, setUsers] = useState([]);
    const [selectedUser, setSelectedUser] = useState(null);
    const [amount, setAmount] = useState('');
    const [senderBalance, setSenderBalance] = useState(0);

    useEffect(() => {
        const fetchUsers = () => {
            const usersRef = ref(database, 'users');

            const unsubscribeUsers = onValue(usersRef, (snapshot) => {
                const usersData = snapshot.val();
                if (usersData) {
                    const userList = Object.keys(usersData)
                        .map(key => ({
                            uid: key,
                            displayName: usersData[key].displayName || 'Unknown User',
                        }))
                        .filter(user => user.uid !== auth().currentUser.uid);

                    setUsers(userList);
                }
            });

            return () => unsubscribeUsers();
        };

        const fetchSenderBalance = () => {
            const senderRef = ref(database, `users/${auth().currentUser.uid}/wallet/balance`);

            const unsubscribeBalance = onValue(senderRef, (snapshot) => {
                setSenderBalance(snapshot.val() || 0);
            });

            return () => unsubscribeBalance();
        };

        const unsubscribeUsers = fetchUsers();
        const unsubscribeBalance = fetchSenderBalance();

        return () => {
            unsubscribeUsers();
            unsubscribeBalance();
        };
    }, []);

    const handleSendMoney = async () => {
        const transferAmount = parseFloat(amount);

        if (!selectedUser || isNaN(transferAmount) || transferAmount <= 0) {
            Alert.alert('Error', 'Please select a user and enter a valid amount.');
            return;
        }

        if (senderBalance < transferAmount) {
            Alert.alert('Error', 'Insufficient balance.');
            return;
        }

        try {
            const { platformFee, totalAmount, responsibleParty } = calculatePlatformFee(transferAmount, 'transfer');
            const recipientNetAmount = responsibleParty === 'recipient'
                ? transferAmount - platformFee
                : transferAmount;

            if (isNaN(recipientNetAmount) || isNaN(platformFee)) {
                throw new Error('Invalid fee calculation.');
            }

            const recipientRef = ref(database, `users/${selectedUser}/wallet/balance`);
            const recipientSnapshot = await get(recipientRef);
            const recipientBalance = recipientSnapshot.val() || 0;

            const agbankRef = ref(database, 'agbank/platformFees');
            const agBankSnapshot = await get(agbankRef);
            const currentPlatformFees = agBankSnapshot.val() || 0;

            const updates = {};
            updates[`users/${auth().currentUser.uid}/wallet/balance`] = senderBalance - transferAmount;
            updates[`users/${selectedUser}/wallet/balance`] = recipientBalance + recipientNetAmount;
            updates['agbank/platformFees'] = currentPlatformFees + platformFee;

            await update(ref(database), updates);

            Alert.alert('Success', `AGMoney sent successfully! Recipient received ${recipientNetAmount.toFixed(2)} AGMoney after fees.`);
            setAmount('');
        } catch (error) {
            console.error('Error sending AGMoney:', error);
            Alert.alert('Error', 'An error occurred while sending AGMoney.');
        }
    };

    return (
        <View style={styles.container}>
            <Text style={styles.header}>Send AGMoney</Text>

            <FlatList
                data={users}
                keyExtractor={(item) => item.uid}
                renderItem={({ item }) => (
                    <TouchableOpacity
                        style={[
                            styles.userItem,
                            selectedUser === item.uid && styles.selectedUser,
                        ]}
                        onPress={() => setSelectedUser(item.uid)}
                    >
                        <Text style={styles.userText}>{item.displayName}</Text>
                    </TouchableOpacity>
                )}
            />

            <TextInput
                style={styles.input}
                placeholder="Enter amount"
                keyboardType="numeric"
                value={amount}
                onChangeText={setAmount}
                placeholderTextColor="#bbb"
            />

            <TouchableOpacity
                style={styles.sendButton}
                onPress={handleSendMoney}
            >
                <Text style={styles.buttonText}>Send</Text>
            </TouchableOpacity>
        </View>
    );
};

export default SendAGMoney;
