import { StyleSheet } from 'react-native';

const styles = StyleSheet.create({
    chatContainer: {
        flex: 1,
        backgroundColor: '#121212',
        padding: 20,
    },
    tabs: {
        flexDirection: 'row',
        justifyContent: 'space-around',
        backgroundColor: '#333',
        padding: 10,
        borderRadius: 8,
    },
    tabButton: {
        flex: 1,
        padding: 12,
        alignItems: 'center',
        backgroundColor: '#555',
        borderRadius: 5,
        marginHorizontal: 5,
    },
    tabText: {
        color: '#fff',
        fontWeight: 'bold',
    },
});

export default styles;
