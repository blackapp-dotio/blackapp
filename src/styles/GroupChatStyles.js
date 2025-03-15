import { StyleSheet } from 'react-native';

const styles = StyleSheet.create({
    container: { flex: 1, flexDirection: 'row', backgroundColor: '#121212' },
    sidebar: { width: '30%', padding: 10, backgroundColor: '#222' },
    title: { color: 'white', fontSize: 18, fontWeight: 'bold', marginBottom: 10 },
    createGroup: { flexDirection: 'row', marginBottom: 10 },
    input: { flex: 1, backgroundColor: '#333', color: 'white', padding: 10, borderRadius: 5 },
    createButton: { marginLeft: 10, padding: 10, backgroundColor: '#007bff', borderRadius: 5 },
});

export default styles;
