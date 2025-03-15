import React, { useState, useEffect } from 'react';
import { View, Text, TouchableOpacity, Animated, Image } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import styles from '../styles/WelcomeOverlayStyles'; // Import styles

const WelcomeOverlay = () => {
    const navigation = useNavigation();
    const [fadeAnim] = useState(new Animated.Value(0)); // Initial fade value
    const [logoAnim] = useState(new Animated.Value(0)); // Logo animation

    useEffect(() => {
        // Animate the logo fade-in
        Animated.timing(logoAnim, {
            toValue: 1,
            duration: 1000,
            useNativeDriver: true,
        }).start();

        // Fade in the entire overlay
        Animated.timing(fadeAnim, {
            toValue: 1,
            duration: 500,
            useNativeDriver: true,
        }).start();
    }, []);

    const handleNavigation = (route) => {
        Animated.timing(fadeAnim, {
            toValue: 0,
            duration: 500,
            useNativeDriver: true,
        }).start(() => {
            navigation.navigate(route); // Navigate after fade-out
        });
    };

    return (
        <Animated.View style={[styles.container, { opacity: fadeAnim }]}>
            <View style={styles.content}>
                <Text style={styles.title}>BlackApp</Text>
                <Text style={styles.subtitle}>The Social Business Hub</Text>

                {/* Logo */}
                <Animated.Image
                    source={require('../../assets/logo.png')} // Update the path to match your assets folder
                    style={[styles.logo, { opacity: logoAnim }]}
                    resizeMode="contain"
                />

                {/* Buttons */}
                <View style={styles.buttonContainer}>
                    <TouchableOpacity style={styles.button} onPress={() => handleNavigation('Login')}>
                        <Text style={styles.buttonText}>Sign In</Text>
                    </TouchableOpacity>
                    <TouchableOpacity style={styles.button} onPress={() => handleNavigation('Register')}>
                        <Text style={styles.buttonText}>Register</Text>
                    </TouchableOpacity>
                </View>
            </View>
        </Animated.View>
    );
};

export default WelcomeOverlay;
