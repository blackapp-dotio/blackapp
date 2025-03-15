import React, { useState, useContext } from 'react';
import { View, Text, TextInput, TouchableOpacity, ActivityIndicator, Alert } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import { signInWithEmailAndPassword } from 'firebase/auth';
import { ref, onValue } from 'firebase/database';
import { auth, database } from '../firebase';
import { AuthContext } from '../contexts/AuthContext';
import styles from '../styles/LoginStyles';

const Login = () => {
    const [email, setEmail] = useState('');
    const [password, setPassword] = useState('');
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState(null);
    const [verificationPendingUser, setVerificationPendingUser] = useState(null);
    const { login } = useContext(AuthContext);
    const navigation = useNavigation();

    // Preload feed data into AsyncStorage
    const preloadFeedData = () => {
        return new Promise((resolve) => {
            const feedRef = ref(database, 'feed');
            onValue(feedRef, (snapshot) => {
                const feedData = snapshot.val();
                if (feedData) {
                    resolve(Object.values(feedData));
                } else {
                    resolve([]);
                }
            });
        });
    };

    // Handle login
    const handleLogin = async () => {
        setLoading(true);
        setError(null);

        try {
            const userCredential = await signInWithEmailAndPassword(auth, email, password);
            const user = userCredential.user;

            if (!user.emailVerified) {
                setError('Your email is not verified. Please check your inbox.');
                setVerificationPendingUser(user);
                setLoading(false);
                return;
            }

            // Preload feed data
            await preloadFeedData();

            // Save login session
            if (login) {
                login(user);
            } else {
                console.error('AuthContext login function not found.');
            }

            navigation.navigate('Profile', { userId: user.uid }); // Navigate to Profile
        } catch (error) {
            setError('Failed to log in. Check your credentials.');
            console.error('Login Error:', error);
        } finally {
            setLoading(false);
        }
    };

    // Resend verification email
    const resendVerificationEmail = async () => {
        if (verificationPendingUser) {
            try {
                await verificationPendingUser.reload();
                const user = auth.currentUser;

                if (!user.emailVerified) {
                    await user.sendEmailVerification();
                    Alert.alert('Verification email sent!', 'Check your inbox.');
                } else {
                    Alert.alert('Your email is already verified.');
                }
            } catch (error) {
                console.error('Error resending verification email:', error);
                Alert.alert('Error', 'Failed to send verification email.');
            }
        }
    };

    return (
        <View style={styles.container}>
            <Text style={styles.title}>Login</Text>

            <TextInput
                style={styles.input}
                placeholder="Email"
                placeholderTextColor="#aaa"
                value={email}
                onChangeText={setEmail}
                keyboardType="email-address"
                autoCapitalize="none"
            />

            <TextInput
                style={styles.input}
                placeholder="Password"
                placeholderTextColor="#aaa"
                value={password}
                onChangeText={setPassword}
                secureTextEntry
            />

            {error && <Text style={styles.errorText}>{error}</Text>}

            <TouchableOpacity style={styles.button} onPress={handleLogin} disabled={loading}>
                {loading ? <ActivityIndicator color="#fff" /> : <Text style={styles.buttonText}>Login</Text>}
            </TouchableOpacity>

            {/* Resend Verification Email */}
            {verificationPendingUser && (
                <TouchableOpacity style={styles.verificationButton} onPress={resendVerificationEmail}>
                    <Text style={styles.verificationText}>Resend Verification Email</Text>
                </TouchableOpacity>
            )}

            {/* Register & Password Reset Links */}
            <TouchableOpacity onPress={() => navigation.navigate('Register')}>
                <Text style={styles.linkText}>Don't have an account? Register</Text>
            </TouchableOpacity>

            <TouchableOpacity onPress={() => navigation.navigate('PasswordReset')}>
                <Text style={styles.linkText}>Forgot your password? Reset Password</Text>
            </TouchableOpacity>
        </View>
    );
};

export default Login;
