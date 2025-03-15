import React, { useEffect, useState, useContext } from 'react';
import { View, Text, FlatList, Image, TouchableOpacity, TextInput, Modal, ActivityIndicator, Alert, StyleSheet } from 'react-native';
import { onValue, update, remove, push, get, ref } from 'firebase/database';
import { getStorage, ref as storageRef, uploadBytes, getDownloadURL } from 'firebase/storage';
import { getAuth } from 'firebase/auth';
import { useNavigation } from '@react-navigation/native';
import { AuthContext } from '../contexts/AuthContext';
import { database } from '../firebase';
import { calculatePlatformFee } from '../utils/feeUtils';
import Icon from 'react-native-vector-icons/MaterialIcons';
import axios from 'axios';

const RSS_FEED_URLS = [
    'https://rss.app/feeds/nsmT2WdQXSlshmcy.xml',
    'https://rss.app/feeds/XqrrnyuiP2E5gvZY.xml',
    'https://rss.app/feeds/uCjXryL38K1J4e29.xml',
    'https://rss.app/feeds/pv5YufdSsNN6ROH5.xml',
    'https://rss.app/feeds/keM7mXLp4OlutaGg.xml',
    'https://rss.app/feeds/KwsTlmbvwXiY4YX6.xml',
    'https://rss.app/feeds/fQ6cY8V57Sk5ayox.xml',
];

const Events = () => {
    const [rssEvents, setRssEvents] = useState([]);
    const [userEvents, setUserEvents] = useState([]);
    const [walletBalance, setWalletBalance] = useState(0);
    const [selectedEvent, setSelectedEvent] = useState(null);
    const [loading, setLoading] = useState(false);
    const navigation = useNavigation();
    const { user } = useContext(AuthContext);
    const auth = getAuth();

    useEffect(() => {
        fetchRSSFeeds();
        fetchUserEvents();
        fetchWalletBalance();
    }, []);

    const fetchUserEvents = () => {
        const userEventsRef = ref(database, 'userEvents');
        onValue(userEventsRef, (snapshot) => {
            if (snapshot.exists()) {
                const loadedUserEvents = Object.entries(snapshot.val()).map(([key, value]) => ({
                    id: key,
                    ...value,
                }));
                setUserEvents(loadedUserEvents.reverse());
            } else {
                setUserEvents([]);
            }
        });
    };

    const fetchWalletBalance = () => {
        if (user) {
            const walletRef = ref(database, `users/${user.uid}/wallet/balance`);
            onValue(walletRef, (snapshot) => {
                setWalletBalance(snapshot.val() || 0);
            });
        }
    };

    const fetchRSSFeeds = async () => {
        setLoading(true);
        let allEvents = [];

        for (const url of RSS_FEED_URLS) {
            try {
                const response = await axios.get(url);
                const parsedEvents = response.data.items.map((item) => ({
                    id: item.guid || item.link,
                    title: item.title,
                    link: item.link,
                    description: item.description || 'No description available.',
                    pubDate: item.pubDate,
                    imageUrl: item.enclosure?.url || '',
                }));
                allEvents.push(...parsedEvents);
            } catch (error) {
                console.error(`Failed to fetch RSS feed from ${url}:`, error);
            }
        }

        setRssEvents(allEvents);
        setLoading(false);
    };

    const handleBuyTickets = (event) => {
        setSelectedEvent(event);
        Alert.alert(
            'Confirm Purchase',
            `Buy ticket for ${event.ticketPrice} AGMoney?`,
            [
                { text: 'Cancel', style: 'cancel' },
                { text: 'Confirm', onPress: confirmPurchase },
            ]
        );
    };

    const confirmPurchase = async () => {
        if (!selectedEvent) return;
        const ticketPrice = parseFloat(selectedEvent.ticketPrice);
        if (isNaN(ticketPrice)) {
            Alert.alert('Error', 'Invalid ticket price.');
            return;
        }

        const { platformFee, totalAmount } = calculatePlatformFee(ticketPrice, 'purchase');

        if (walletBalance < totalAmount) {
            Alert.alert('Error', 'Insufficient balance.');
            return;
        }

        const newBalance = walletBalance - totalAmount;
        const updates = {};
        updates[`users/${user.uid}/wallet/balance`] = newBalance;

        const organizerBalanceRef = ref(database, `users/${selectedEvent.creatorId}/wallet/balance`);
        const organizerSnapshot = await get(organizerBalanceRef);
        const organizerBalance = parseFloat(organizerSnapshot.val()) || 0;

        updates[`users/${selectedEvent.creatorId}/wallet/balance`] = organizerBalance + ticketPrice;

        await update(ref(database), updates);
        Alert.alert('Success', 'Ticket purchased successfully!');
    };

    const renderEventItem = ({ item }) => (
        <View style={styles.eventCard}>
            <Text style={styles.eventTitle}>{item.title}</Text>
            {item.imageUrl ? <Image source={{ uri: item.imageUrl }} style={styles.eventImage} /> : null}
            <Text style={styles.eventDescription}>{item.description}</Text>
            <View style={styles.eventActions}>
                <TouchableOpacity style={styles.button} onPress={() => handleBuyTickets(item)}>
                    <Text style={styles.buttonText}>Buy Ticket</Text>
                </TouchableOpacity>
            </View>
        </View>
    );

    return (
        <View style={styles.container}>
            {loading ? <ActivityIndicator size="large" color="white" /> : null}
            <FlatList
                data={[...userEvents, ...rssEvents]}
                renderItem={renderEventItem}
                keyExtractor={(item) => item.id}
            />
        </View>
    );
};

const styles = StyleSheet.create({
    container: { flex: 1, backgroundColor: 'black', padding: 10 },
    eventCard: { backgroundColor: '#222', padding: 15, marginBottom: 10, borderRadius: 10 },
    eventTitle: { fontSize: 16, fontWeight: 'bold', color: 'white' },
    eventImage: { width: '100%', height: 200, borderRadius: 10, marginVertical: 10 },
    eventDescription: { color: 'white' },
    eventActions: { flexDirection: 'row', justifyContent: 'space-between', marginTop: 10 },
    button: { backgroundColor: '#007bff', padding: 10, borderRadius: 5, alignItems: 'center' },
    buttonText: { color: 'white', fontWeight: 'bold' },
});

export default Events;
