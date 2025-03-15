import { StyleSheet } from 'react-native';

export default StyleSheet.create({
    container: {
        flex: 1,
        justifyContent: 'center',
        alignItems: 'center',
        backgroundColor: '#121212',
        padding: 20,
    },
    title: {
        fontSize: 24,
        fontWeight: 'bold',
        color: '#fff',
        marginBottom: 20,
    },
    input: {
        width: '100%',
        padding: 12,
        borderWidth: 1,
        borderColor: '#444',
        borderRadius: 8,
        backgroundColor: '#222',
        color: '#fff',
        marginBottom: 10,
    },
    button: {
        width: '100%',
        padding: 12,
        backgroundColor: '#007bff',
        borderRadius: 8,
        alignItems: 'center',
        marginVertical: 10,
    },
    buttonText: {
        fontSize: 16,
        color: '#fff',
    },
    verificationButton: {
        marginTop: 10,
    },
    verificationText: {
        color: '#ffcc00',
        textDecorationLine: 'underline',
    },
    linkText: {
        color: '#00bcd4',
        textDecorationLine: 'underline',
        marginTop: 10,
    },
    errorText: {
        color: 'red',
        marginBottom: 10,
    },
});
