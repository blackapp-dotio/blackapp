import React, { useContext, useState } from 'react';
import { NavigationContainer } from '@react-navigation/native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { View, Image, StyleSheet, TouchableOpacity } from 'react-native';
import { AuthProvider, AuthContext } from './contexts/AuthContext';
import Feed from './components/Feed';
import Events from './components/Events';
import Login from './components/Login';
import Register from './components/Register';
import Profile from './components/Profile';
import PasswordReset from './components/PasswordReset';
import ChatList from './components/ChatList';
import ChatConversation from './components/ChatConversation';
import Wallet from './components/Wallet';
import WelcomeOverlay from './components/WelcomeOverlay';
import Explore from './components/Explore';
import Support from './components/Support';
import AGBankDashboard from './components/AGBankDashboard';
import { createTheme, ThemeProvider } from '@mui/material/styles';
import Icon from 'react-native-vector-icons/MaterialIcons';

// Bottom Tab Navigator
const Tab = createBottomTabNavigator();
const Stack = createNativeStackNavigator();

const theme = {
  dark: true,
  colors: {
    background: '#000000',
    text: '#FFFFFF',
  },
};

const MainTabs = () => {
  return (
    <Tab.Navigator
      screenOptions={{
        tabBarStyle: { backgroundColor: '#000', borderTopColor: 'gray' },
        tabBarActiveTintColor: '#ffcc00',
      }}
    >
      <Tab.Screen
        name="Feed"
        component={Feed}
        options={{
          tabBarIcon: ({ color, size }) => <Icon name="home" color={color} size={size} />,
        }}
      />
      <Tab.Screen
        name="Events"
        component={Events}
        options={{
          tabBarIcon: ({ color, size }) => <Icon name="event" color={color} size={size} />,
        }}
      />
      <Tab.Screen
        name="Profile"
        component={Profile}
        options={{
          tabBarIcon: ({ color, size }) => <Icon name="account-circle" color={color} size={size} />,
        }}
      />
      <Tab.Screen
        name="Chat"
        component={ChatList}
        options={{
          tabBarIcon: ({ color, size }) => <Icon name="chat" color={color} size={size} />,
        }}
      />
      <Tab.Screen
        name="Wallet"
        component={Wallet}
        options={{
          tabBarIcon: ({ color, size }) => <Icon name="account-balance-wallet" color={color} size={size} />,
        }}
      />
    </Tab.Navigator>
  );
};

const App = () => {
  const { user } = useContext(AuthContext);
  return (
    <ThemeProvider theme={theme}>
      <View style={styles.container}>
        {!user && <WelcomeOverlay />}
        <NavigationContainer>
          <Stack.Navigator screenOptions={{ headerShown: false }}>
            <Stack.Screen name="Main" component={MainTabs} />
            <Stack.Screen name="Login" component={Login} />
            <Stack.Screen name="Register" component={Register} />
            <Stack.Screen name="PasswordReset" component={PasswordReset} />
            <Stack.Screen name="ChatConversation" component={ChatConversation} />
            <Stack.Screen name="Explore" component={Explore} />
            <Stack.Screen name="Support" component={Support} />
            <Stack.Screen name="AGBankDashboard" component={AGBankDashboard} />
          </Stack.Navigator>
        </NavigationContainer>

        {/* Footer Logo */}
        <TouchableOpacity style={styles.logoContainer} onPress={() => console.log('AG Global Logo Clicked')}>
          <Image source={require('./assets/ag-global-logo.png')} style={styles.logo} />
        </TouchableOpacity>
      </View>
    </ThemeProvider>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
  },
  logoContainer: {
    position: 'absolute',
    bottom: 10,
    right: 10,
    padding: 10,
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
    borderRadius: 50,
  },
  logo: {
    width: 50,
    height: 50,
    resizeMode: 'contain',
  },
});

const AppWrapper = () => (
  <AuthProvider>
    <App />
  </AuthProvider>
);

export default AppWrapper;
