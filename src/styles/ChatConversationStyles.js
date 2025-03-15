import { StyleSheet } from 'react-native';

const styles = StyleSheet.create({
    container: {
        flex: 1,
        backgroundColor: '#121212',
        padding: 10,
    },
    message: {
        padding: 10,
        borderRadius: 10,
        marginVertical: 5,
        maxWidth: '70%',
    },
    sent: {
        alignSelf: 'flex-end',
        backgroundColor: '#007bff',
    },
    received: {
        alignSelf: 'flex-start',
        backgroundColor: '#444',
    },
    messageText: {
        color: 'white',
        fontSize: 16,
    },
    timestamp: {
        fontSize: 12,
        color: '#bbb',
        marginTop: 5,
    },
    inputContainer: {
        flexDirection: 'row',
        alignItems: 'center',
        padding: 10,
        borderTopWidth: 1,
        borderColor: '#333',
    },
    input: {
        flex: 1,
        backgroundColor: '#222',
        color: '#fff',
        borderRadius: 5,
        padding: 10,
    },
    sendButton: {
        marginLeft: 10,
        padding: 10,
        backgroundColor: '#007bff',
        borderRadius: 5,
    },
    emojiButton: {
        marginLeft: 10,
        padding: 10,
    },
    deleteChatButton: {
        marginLeft: 10,
    },
});

export default styles;
