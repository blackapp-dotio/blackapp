import { StyleSheet } from 'react-native';

const styles = StyleSheet.create({
    container: {
        flex: 1,
        backgroundColor: '#121212',
        padding: 20,
    },
    header: {
        fontSize: 22,
        fontWeight: 'bold',
        color: '#007bff',
        marginBottom: 20,
        textAlign: 'center',
    },
    userItem: {
        padding: 15,
        backgroundColor: '#222',
        marginVertical: 5,
        borderRadius: 5,
    },
    selectedUser: {
        backgroundColor: '#007bff',
    },
    userText: {
        color: 'white',
        fontSize: 16,
    },
    input: {
        backgroundColor: '#222',
        color: 'white',
        padding: 12,
        borderRadius: 5,
        fontSize: 16,
        marginTop: 10,
    },
    sendButton: {
        backgroundColor: '#28a745',
        padding: 15,
        borderRadius: 5,
        marginTop: 20,
        alignItems: 'center',
    },
    buttonText: {
        color: 'white',
        fontSize: 18,
        fontWeight: 'bold',
    },
});

export default styles;
