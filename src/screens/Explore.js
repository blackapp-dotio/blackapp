import React, { useState, useEffect } from 'react';
import { View, Text, Image, FlatList, TouchableOpacity, ActivityIndicator } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import { ref, onValue } from 'firebase/database';
import { database } from '../firebase';
import styles from '../styles/ExploreStyles';

const Explore = () => {
    const [brands, setBrands] = useState([]);
    const [loading, setLoading] = useState(true);
    const navigation = useNavigation();

    useEffect(() => {
        const brandsRef = ref(database, 'brands');
        const unsubscribe = onValue(brandsRef, (snapshot) => {
            const data = snapshot.val();
            const approvedBrands = Object.values(data || {}).filter(
                (brand) => brand.status === 'approved' && brand.isPublished
            );
            setBrands(approvedBrands);
            setLoading(false);
        });

        return () => unsubscribe(); // Clean up the listener
    }, []);

    if (loading) {
        return (
            <View style={styles.loadingContainer}>
                <ActivityIndicator size="large" color="#007bff" />
            </View>
        );
    }

    return (
        <View style={styles.container}>
            <Text style={styles.title}>Explore Brands</Text>
            <FlatList
                data={brands}
                keyExtractor={(item) => item.id}
                numColumns={3} // Adjust grid layout
                contentContainerStyle={styles.grid}
                renderItem={({ item }) => (
                    <TouchableOpacity
                        style={styles.brandCard}
                        onPress={() => navigation.navigate('BrandDetails', { brandName: item.businessName })}
                    >
                        <Image source={{ uri: item.logoUrl }} style={styles.brandLogo} />
                        <Text style={styles.brandName}>{item.businessName}</Text>
                    </TouchableOpacity>
                )}
            />
        </View>
    );
};

export default Explore;
