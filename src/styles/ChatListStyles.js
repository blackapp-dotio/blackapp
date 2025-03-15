import { StyleSheet } from 'react-native';

const styles = StyleSheet.create({
    container: {
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
    searchInput: {
        marginTop: 10,
        backgroundColor: '#222',
        padding: 10,
        borderRadius: 5,
        color: '#fff',
    },
    chatItem: {
        padding: 15,
        backgroundColor: '#333',
        marginVertical: 5,
        borderRadius: 8,
    },
    chatName: {
        fontSize: 16,
        fontWeight: 'bold',
        color: '#fff',
    },
    lastMessage: {
        fontSize: 14,
        color: '#bbb',
    },
    unreadBadge: {
        color: '#ffcc00',
        fontWeight: 'bold',
    },
});

export default styles;
