import React, { useState, useContext } from 'react';
import { View, Text, TextInput, TouchableOpacity, Alert, ActivityIndicator, StyleSheet } from 'react-native';
import { AuthContext } from '../contexts/AuthContext';
import { ref, push, update } from 'firebase/database';
import { getStorage, ref as storageRef, uploadBytes, getDownloadURL } from 'firebase/storage';
import { database } from '../firebase';
import * as ImagePicker from 'expo-image-picker';

const CreateEventForm = ({ onEventCreated }) => {
    const { user } = useContext(AuthContext);
    const [newEvent, setNewEvent] = useState({
        name: '',
        description: '',
        date: '',
        location: '',
        ticketPrice: '',
        ticketsAvailable: '',
    });
    const [mediaFile, setMediaFile] = useState(null);
    const [loading, setLoading] = useState(false);

    // Handle picking an image from the device
    const pickMedia = async () => {
        let result = await ImagePicker.launchImageLibraryAsync({
            mediaTypes: ImagePicker.MediaTypeOptions.All,
            allowsEditing: true,
            quality: 1,
        });

        if (!result.canceled) {
            setMediaFile(result.assets[0]);
        }
    };

    // Handle event creation
    const handleCreateEvent = async () => {
        if (!newEvent.name || !newEvent.date || !newEvent.ticketPrice) {
            Alert.alert('Missing Information', 'Please fill out all required fields.');
            return;
        }

        try {
            setLoading(true);
            const eventRef = push(ref(database, 'userEvents'));
            let mediaUrl = '';

            if (mediaFile) {
                const storage = getStorage();
                const mediaStorageRef = storageRef(storage, `events/${eventRef.key}/${mediaFile.fileName}`);
                const response = await fetch(mediaFile.uri);
                const blob = await response.blob();
                await uploadBytes(mediaStorageRef, blob);
                mediaUrl = await getDownloadURL(mediaStorageRef);
            }

            const eventData = {
                ...newEvent,
                id: eventRef.key,
                mediaUrl,
                creatorId: user.uid,
                timestamp: Date.now(),
            };

            await update(eventRef, eventData);

            Alert.alert('Success', 'Event created successfully.');
            if (onEventCreated) {
                onEventCreated(eventData);
            }

            // Reset form
            setNewEvent({ name: '', description: '', date: '', location: '', ticketPrice: '', ticketsAvailable: '' });
            setMediaFile(null);
        } catch (error) {
            console.error('Error creating event:', error);
            Alert.alert('Error', 'An error occurred while creating the event.');
        } finally {
            setLoading(false);
        }
    };

    return (
        <View style={styles.container}>
            <Text style={styles.title}>Create a New Event</Text>
            <TextInput
                style={styles.input}
                placeholder="Event Name"
                placeholderTextColor="gray"
                value={newEvent.name}
                onChangeText={(text) => setNewEvent({ ...newEvent, name: text })}
            />
            <TextInput
                style={styles.input}
                placeholder="Event Description"
                placeholderTextColor="gray"
                multiline
                value={newEvent.description}
                onChangeText={(text) => setNewEvent({ ...newEvent, description: text })}
            />
            <TextInput
                style={styles.input}
                placeholder="Event Date (YYYY-MM-DD)"
                placeholderTextColor="gray"
                value={newEvent.date}
                onChangeText={(text) => setNewEvent({ ...newEvent, date: text })}
            />
            <TextInput
                style={styles.input}
                placeholder="Event Location"
                placeholderTextColor="gray"
                value={newEvent.location}
                onChangeText={(text) => setNewEvent({ ...newEvent, location: text })}
            />
            <TextInput
                style={styles.input}
                placeholder="Ticket Price (AGMoney)"
                placeholderTextColor="gray"
                keyboardType="numeric"
                value={newEvent.ticketPrice}
                onChangeText={(text) => setNewEvent({ ...newEvent, ticketPrice: text })}
            />
            <TextInput
                style={styles.input}
                placeholder="Tickets Available"
                placeholderTextColor="gray"
                keyboardType="numeric"
                value={newEvent.ticketsAvailable}
                onChangeText={(text) => setNewEvent({ ...newEvent, ticketsAvailable: text })}
            />
            <TouchableOpacity style={styles.mediaButton} onPress={pickMedia}>
                <Text style={styles.mediaButtonText}>{mediaFile ? 'Media Selected ✅' : 'Select Media (Image/Video)'}</Text>
            </TouchableOpacity>
            <TouchableOpacity style={styles.createButton} onPress={handleCreateEvent} disabled={loading}>
                {loading ? <ActivityIndicator color="white" /> : <Text style={styles.createButtonText}>Create Event</Text>}
            </TouchableOpacity>
        </View>
    );
};

const styles = StyleSheet.create({
    container: { backgroundColor: '#222', padding: 20, borderRadius: 10, alignItems: 'center' },
    title: { fontSize: 18, fontWeight: 'bold', color: 'white', marginBottom: 10 },
    input: { width: '100%', backgroundColor: '#333', color: 'white', padding: 10, borderRadius: 5, marginBottom: 10 },
    mediaButton: { backgroundColor: '#555', padding: 10, borderRadius: 5, alignItems: 'center', marginBottom: 10 },
    mediaButtonText: { color: 'white' },
    createButton: { backgroundColor: '#007bff', padding: 10, borderRadius: 5, alignItems: 'center' },
    createButtonText: { color: 'white', fontWeight: 'bold' },
});

export default CreateEventForm;
