import React, { useEffect, useState, useContext, useCallback } from 'react';
import { View, Text, FlatList, Image, TextInput, TouchableOpacity, Modal, ActivityIndicator, Alert, StyleSheet } from 'react-native';
import { onValue, update, remove, push, get, ref } from 'firebase/database';
import { getAuth } from 'firebase/auth';
import { useNavigation } from '@react-navigation/native';
import { AuthContext } from '../contexts/AuthContext';
import { database } from '../firebase';
import Icon from 'react-native-vector-icons/MaterialIcons';
import axios from 'axios';

// ✅ Full list of RSS feed URLs (NO OMITTED DATA)
const RSS_FEED_URLS = [
    'https://rss.app/feeds/hXAXAKLk6J0sbRX0.xml',
    'https://rss.app/feeds/a0BC3EgcQ2gi6jt9.xml',
    'https://rss.app/feeds/MDlghVUX5yvecvRG.xml',
    'https://www.pulse.ng/entertainment/rss',
    'https://www.theafricanmirror.africa/arts-and-entertainment/feed/',
    'https://www.africanexponent.com/rss/entertainment',
    'https://www.okayafrica.com/music/rss/',
    'https://celebrity.nine.com.au/rss',
    'https://www.allabouttrh.com/feed/',
    'https://bckonline.com/feed/',
    'https://balleralert.com/feed/',
    'https://rss.app/feeds/nsmT2WdQXSlshmcy.xml',
    'https://rss.app/feeds/XqrrnyuiP2E5gvZY.xml',
    'https://rss.app/feeds/Vgjdsm6FBHT3mj4G.xml',
    'https://www.buzzfeed.com/celebrity.xml',
    'https://rss.app/feeds/3zTVOBAND5ezpD5g.xml',
    'https://sahiphopmag.co.za/feed/',
    'https://naijavibes.com/feed/',
    'https://tooxclusive.com/feed/',
    'https://theshaderoom.com/latest-tea/feed/',
    'https://www.ghanacelebrities.com/feed/',
    'https://theblackmedia.org/feed/',
    'https://afro.com/section/arts-entertainment/feed/',
    'https://globalgrind.com/category/entertainment/feed/',
    'https://www.thesouthafrican.com/culture/entertainment/',
    'https://rss.app/feeds/keM7mXLp4OlutaGg.xml',
    'https://rss.app/feeds/KwsTlmbvwXiY4YX6.xml',
    'https://rss.app/feeds/fQ6cY8V57Sk5ayox.xml',
];

const Feed = () => {
    const [feedContent, setFeedContent] = useState([]);
    const [likes, setLikes] = useState({});
    const [newPost, setNewPost] = useState('');
    const [loadingMore, setLoadingMore] = useState(false);
    const navigation = useNavigation();
    const { user } = useContext(AuthContext);
    const auth = getAuth();
    const itemsPerPage = 5;
    const [startIndex, setStartIndex] = useState(0);
    
    // Fetch RSS feeds and user-generated posts
    const fetchRSSFeeds = useCallback(async () => {
        let allRssItems = [];

        for (const url of RSS_FEED_URLS) {
            try {
                const response = await axios.get(url);
                const parsedItems = response.data.items.map((item) => ({
                    id: item.guid || item.link,
                    title: item.title,
                    link: item.link,
                    image: item.enclosure?.url || '',
                    pubDate: item.pubDate,
                    type: 'rss',
                }));
                allRssItems.push(...parsedItems);
            } catch (error) {
                console.error(`Failed to fetch RSS feed from ${url}:`, error.message);
            }
        }

        return allRssItems.sort((a, b) => new Date(b.pubDate) - new Date(a.pubDate));
    }, []);

    const fetchUserPosts = async () => {
        const userPostsRef = ref(database, 'feed');
        return new Promise((resolve) => {
            onValue(userPostsRef, async (snapshot) => {
                const userPosts = snapshot.val();
                if (userPosts) {
                    const postsWithUserInfo = await Promise.all(
                        Object.values(userPosts).map(async (post) => {
                            return {
                                ...post,
                                type: 'user',
                            };
                        })
                    );
                    resolve(postsWithUserInfo.reverse());
                } else {
                    resolve([]);
                }
            });
        });
    };

    // Load more posts for infinite scrolling
    const loadMorePosts = async () => {
        if (loadingMore) return;
        setLoadingMore(true);

        try {
            const rssContent = await fetchRSSFeeds();
            const userPosts = await fetchUserPosts();
            const combinedContent = [...userPosts, ...rssContent];
            const newItems = combinedContent.slice(startIndex, startIndex + itemsPerPage);

            setFeedContent((prev) => [...prev, ...newItems]);
            setStartIndex(startIndex + itemsPerPage);
        } catch (error) {
            console.error('Error loading posts:', error);
        } finally {
            setLoadingMore(false);
        }
    };

    useEffect(() => {
        loadMorePosts();
    }, []);

    const renderFeedItem = ({ item }) => (
        <View style={styles.feedItem}>
            <Text style={styles.profileName}>{item.title || 'No Title'}</Text>
            {item.image ? <Image source={{ uri: item.image }} style={styles.feedImage} /> : null}
            <Text style={styles.postText}>{item.link ? 'Click to read more' : ''}</Text>
        </View>
    );

    return (
        <View style={styles.container}>
            <FlatList
                data={feedContent}
                renderItem={renderFeedItem}
                keyExtractor={(item) => item.id}
                onEndReached={loadMorePosts}
                onEndReachedThreshold={0.5}
                ListFooterComponent={loadingMore ? <ActivityIndicator size="large" color="white" /> : null}
            />
        </View>
    );
};

const styles = StyleSheet.create({
    container: { flex: 1, backgroundColor: 'black', padding: 10 },
    feedItem: { backgroundColor: '#222', padding: 15, marginBottom: 10, borderRadius: 10 },
    profileName: { fontSize: 16, fontWeight: 'bold', color: 'white' },
    feedImage: { width: '100%', height: 200, borderRadius: 10, marginVertical: 10 },
    postText: { color: 'white' },
});

export default Feed;
