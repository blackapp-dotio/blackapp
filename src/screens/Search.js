import React, { useState } from 'react';
import { View, Text, TextInput, TouchableOpacity, FlatList, Image, ActivityIndicator } from 'react-native';
import { ref, get } from 'firebase/database';
import { database } from '../firebase';
import { useNavigation } from '@react-navigation/native';
import styles from '../styles/SearchStyles';

const Search = () => {
    const [query, setQuery] = useState('');
    const [results, setResults] = useState([]);
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState('');
    const navigation = useNavigation();

    const handleSearch = async () => {
        if (!query.startsWith('@')) {
            setError('Invalid search query. Please use @ to search for users.');
            setResults([]);
            return;
        }

        setError('');
        setLoading(true);
        setResults([]);

        try {
            await searchUsers();
        } catch (err) {
            console.error('Search error:', err);
            setError('An error occurred while searching. Please try again.');
        } finally {
            setLoading(false);
        }
    };

    const searchUsers = async () => {
        const usersRef = ref(database, 'users');
        const snapshot = await get(usersRef);

        if (snapshot.exists()) {
            const usersData = snapshot.val();
            const filteredUsers = Object.entries(usersData)
                .filter(([_, user]) => user?.displayName?.toLowerCase().includes(query.slice(1).toLowerCase()))
                .map(([key, user]) => ({
                    displayName: user.displayName,
                    profilePicture: user.profilePicture || 'https://via.placeholder.com/40',
                    userId: key,  
                }));

            setResults(filteredUsers);
        } else {
            setResults([]);
        }
    };

    const handleResultClick = (result) => {
        if (result?.userId) {
            navigation.navigate('Profile', { userId: result.userId });
        } else {
            setError('Unable to navigate to user profile. Missing user ID.');
            console.error('Missing userId for result:', result);
        }
    };

    return (
        <View style={styles.container}>
            <TextInput
                style={styles.input}
                placeholder="Search for @users"
                placeholderTextColor="#bbb"
                value={query}
                onChangeText={setQuery}
            />
            <TouchableOpacity style={styles.button} onPress={handleSearch}>
                <Text style={styles.buttonText}>Search</Text>
            </TouchableOpacity>

            {loading && <ActivityIndicator size="large" color="#007bff" />}
            {error && <Text style={styles.error}>{error}</Text>}

            <FlatList
                data={results}
                keyExtractor={(item) => item.userId}
                renderItem={({ item }) => (
                    <TouchableOpacity style={styles.resultItem} onPress={() => handleResultClick(item)}>
                        <Image source={{ uri: item.profilePicture }} style={styles.profilePic} />
                        <Text style={styles.resultText}>{item.displayName}</Text>
                    </TouchableOpacity>
                )}
                ListEmptyComponent={!loading && query ? <Text style={styles.noResults}>No results found</Text> : null}
            />
        </View>
    );
};

export default Search;
