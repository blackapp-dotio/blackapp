import React, { useState, useEffect, useContext } from 'react';
import { View, Text, TextInput, TouchableOpacity, FlatList, Alert, ActivityIndicator } from 'react-native';
import { AuthContext } from '../contexts/AuthContext';
import { useNavigation } from '@react-navigation/native';
import { ref, onValue, update, push, get } from 'firebase/database';
import { database } from '../firebase';
import styles from '../styles/WalletStyles';
import Icon from 'react-native-vector-icons/FontAwesome';

const Wallet = () => {
  const { user } = useContext(AuthContext);
  const navigation = useNavigation();
  const [balance, setBalance] = useState(0);
  const [transactions, setTransactions] = useState([]);
  const [userNames, setUserNames] = useState({});
  const [cashoutAmount, setCashoutAmount] = useState('');
  const [depositAmount, setDepositAmount] = useState('');
  const [isProcessing, setIsProcessing] = useState(false);
  const [paymentStatus, setPaymentStatus] = useState(null);
  const [selectedMethod, setSelectedMethod] = useState(null);
  const [paypalEmail, setPayPalEmail] = useState('');
  const [cashAppUsername, setCashAppUsername] = useState('');
  const [momoPhoneNumber, setMomoPhoneNumber] = useState('');
  const [platformFeeBalance, setPlatformFeeBalance] = useState(0);

  useEffect(() => {
    if (user) {
      const balanceRef = ref(database, `users/${user.uid}/wallet/balance`);
      onValue(balanceRef, (snapshot) => setBalance(snapshot.val() || 0));

      const transactionsRef = ref(database, 'transactions');
      onValue(transactionsRef, (snapshot) => {
        const transactionsData = snapshot.val();
        if (transactionsData) {
          const filteredTransactions = Object.values(transactionsData)
            .filter(
              (transaction) =>
                transaction.senderId === user.uid ||
                transaction.recipientId === user.uid
            )
            .sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));
          setTransactions(filteredTransactions);
        } else {
          setTransactions([]);
        }
      });

      const usersRef = ref(database, 'users');
      onValue(usersRef, (snapshot) => {
        const usersData = snapshot.val();
        const names = {};
        Object.keys(usersData || {}).forEach((uid) => {
          names[uid] = usersData[uid].displayName;
        });
        setUserNames(names);
      });
    }
  }, [user?.uid]);

  const calculatePlatformFee = (amount) => {
    const fee = amount * 0.02;
    setPlatformFeeBalance((prevBalance) => prevBalance + fee);
    const agBankRef = ref(database, 'AGBank/totalFees');
    update(agBankRef, { totalFees: platformFeeBalance + fee });
    return fee;
  };

  const logTransaction = async (transaction) => {
    const transactionsRef = ref(database, 'transactions');
    await push(transactionsRef, transaction);
  };

  const handleDeposit = () => {
    if (!depositAmount || depositAmount <= 0) {
      Alert.alert('Error', 'Enter a valid deposit amount.');
      return;
    }

    const newBalance = balance + parseFloat(depositAmount);
    update(ref(database, `users/${user.uid}/wallet/balance`), { balance: newBalance });
    setBalance(newBalance);
    logTransaction({
      senderId: user.uid,
      recipientId: user.uid,
      amount: parseFloat(depositAmount),
      type: 'Deposit',
      method: selectedMethod,
      timestamp: Date.now(),
    });

    setPaymentStatus(`${selectedMethod} deposit successful!`);
    setDepositAmount('');
  };

  const handleCashout = () => {
    if (!cashoutAmount || cashoutAmount <= 0) {
      Alert.alert('Error', 'Enter a valid cashout amount.');
      return;
    }

    const fee = calculatePlatformFee(parseFloat(cashoutAmount));
    const netAmount = parseFloat(cashoutAmount) - fee;

    if (balance < parseFloat(cashoutAmount)) {
      Alert.alert('Error', 'Insufficient balance.');
      return;
    }

    const newBalance = balance - parseFloat(cashoutAmount);
    update(ref(database, `users/${user.uid}/wallet/balance`), { balance: newBalance });
    setBalance(newBalance);
    logTransaction({
      senderId: user.uid,
      recipientId: user.uid,
      amount: netAmount,
      type: 'Cashout',
      method: selectedMethod,
      platformFee: fee,
      timestamp: Date.now(),
    });

    setPaymentStatus(`${selectedMethod} cashout successful!`);
    setCashoutAmount('');
  };

  return (
    <View style={styles.container}>
      <Text style={styles.header}>Your Wallet</Text>

      <View style={styles.balanceCard}>
        <Text style={styles.balanceLabel}>Current Balance</Text>
        <Text style={styles.balanceAmount}>
          <Icon name="dollar" size={24} /> {balance.toFixed(2)}
        </Text>
      </View>

      <Text style={styles.sectionTitle}>Choose a Payment Method</Text>
      <View style={styles.paymentMethods}>
        <TouchableOpacity style={styles.methodButton} onPress={() => setSelectedMethod('CashApp')}>
          <Icon name="money" size={20} color="#fff" />
          <Text style={styles.methodText}>Cash App</Text>
        </TouchableOpacity>
        <TouchableOpacity style={styles.methodButton} onPress={() => setSelectedMethod('PayPal')}>
          <Icon name="paypal" size={20} color="#fff" />
          <Text style={styles.methodText}>PayPal</Text>
        </TouchableOpacity>
        <TouchableOpacity style={styles.methodButton} onPress={() => setSelectedMethod('MOMO')}>
          <Icon name="mobile" size={20} color="#fff" />
          <Text style={styles.methodText}>MOMO</Text>
        </TouchableOpacity>
      </View>

      {selectedMethod && (
        <View style={styles.paymentForm}>
          <TextInput
            style={styles.input}
            placeholder="Enter amount"
            keyboardType="numeric"
            value={depositAmount}
            onChangeText={setDepositAmount}
          />
          <TouchableOpacity style={styles.submitButton} onPress={handleDeposit}>
            <Text style={styles.submitButtonText}>Deposit</Text>
          </TouchableOpacity>

          <TextInput
            style={styles.input}
            placeholder="Enter cashout amount"
            keyboardType="numeric"
            value={cashoutAmount}
            onChangeText={setCashoutAmount}
          />
          <TouchableOpacity style={styles.submitButton} onPress={handleCashout}>
            <Text style={styles.submitButtonText}>Cashout</Text>
          </TouchableOpacity>
        </View>
      )}

      {paymentStatus && <Text style={styles.status}>{paymentStatus}</Text>}

      <FlatList
        data={transactions}
        keyExtractor={(item, index) => index.toString()}
        renderItem={({ item }) => (
          <View style={styles.transactionItem}>
            <Text>{item.type} - ${item.amount.toFixed(2)}</Text>
          </View>
        )}
      />
    </View>
  );
};

export default Wallet;
