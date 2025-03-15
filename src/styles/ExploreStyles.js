import { StyleSheet } from 'react-native';

export default StyleSheet.create({
    container: {
        flex: 1,
        backgroundColor: '#121212',
        padding: 20,
        alignItems: 'center',
    },
    title: {
        fontSize: 24,
        fontWeight: 'bold',
        color: '#ffffff',
        marginBottom: 20,
    },
    grid: {
        justifyContent: 'center',
    },
    brandCard: {
        alignItems: 'center',
        margin: 10,
        padding: 10,
        backgroundColor: '#1f1f1f',
        borderRadius: 10,
        width: 100,
    },
    brandLogo: {
        width: 80,
        height: 80,
        borderRadius: 10,
        resizeMode: 'cover',
    },
    brandName: {
        marginTop: 8,
        fontSize: 14,
        fontWeight: 'bold',
        color: '#ffffff',
        textAlign: 'center',
    },
    loadingContainer: {
        flex: 1,
        justifyContent: 'center',
        alignItems: 'center',
    },
});
