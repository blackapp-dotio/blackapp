import React, { useEffect, useState } from 'react';
import { getDatabase, ref, onValue, push, update, remove, get } from 'firebase/database';
import { getStorage, ref as storageRef, uploadBytes, getDownloadURL } from 'firebase/storage';
import { database, auth } from '../firebaseconfig';
import { useNavigate, useParams } from 'react-router-dom';
import { FaHeart, FaComment, FaShare } from 'react-icons/fa';
import AROrb from './AROrb'; // AI/AR Assistant Orb Placeholder
import './Profile.css';

const Profile = () => {
  const { uid } = useParams();
  const [editing, setEditing] = useState(false);
  const [profileData, setProfileData] = useState({
    displayName: '',
    bio: '',
    profilePicture: 'default-avatar.png',
  });
  const [brandData, setBrandData] = useState({
    businessName: '',
    description: '',
    logo: '',
  });
  const [brands, setBrands] = useState([]);
  const [posts, setPosts] = useState([]);
  const [newPost, setNewPost] = useState('');
  const [mediaFile, setMediaFile] = useState(null);
  const [likes, setLikes] = useState({});
  const [loading, setLoading] = useState(true);
  const [isFollowing, setIsFollowing] = useState(false);
  const [isAdmin, setIsAdmin] = useState(false);
  const navigate = useNavigate();
  const currentUser = auth.currentUser;

  useEffect(() => {
    const fetchProfileData = async () => {
      const userId = uid || currentUser?.uid;
      if (userId) {
        const userRef = ref(database, `users/${userId}`);
        onValue(userRef, (snapshot) => {
          if (snapshot.exists()) {
            setProfileData(snapshot.val());
          }
        });

        const postsRef = ref(database, `posts/${userId}`);
        onValue(postsRef, (snapshot) => {
          if (snapshot.exists()) {
            setPosts(Object.values(snapshot.val()));
          }
        });

        const brandsRef = ref(database, `users/${userId}/brands`);
        onValue(brandsRef, (snapshot) => {
          if (snapshot.exists()) {
            setBrands(Object.values(snapshot.val()));
          }
        });

        const likesRef = ref(database, 'likes');
        onValue(likesRef, (snapshot) => {
          if (snapshot.exists()) {
            setLikes(snapshot.val());
          }
        });

        if (uid && currentUser) {
          const followingRef = ref(database, `following/${currentUser.uid}`);
          onValue(followingRef, (snapshot) => {
            setIsFollowing(!!snapshot.val()?.[uid]);
          });
        }

        if (!uid) {
          const idTokenResult = await currentUser.getIdTokenResult();
          if (idTokenResult.claims.admin || idTokenResult.claims.superAdmin) {
            setIsAdmin(true);
          }
        }
        setLoading(false);
      }
    };
    fetchProfileData();
  }, [uid, currentUser]);

  const handleProfilePictureChange = async (event) => {
    const file = event.target.files[0];
    if (file) {
      const storage = getStorage();
      const profilePictureRef = storageRef(storage, `profile_pictures/${auth.currentUser.uid}`);
      await uploadBytes(profilePictureRef, file);
      const url = await getDownloadURL(profilePictureRef);
      setProfileData({ ...profileData, profilePicture: url });

      if (currentUser) {
        await update(ref(database, `users/${currentUser.uid}`), { profilePicture: url });
      }
    }
  };

  const handleSave = async () => {
    if (currentUser) {
      await update(ref(database, `users/${currentUser.uid}`), profileData);
    }
    setEditing(false);
  };

  const handlePost = async () => {
    if (newPost.trim() === '' && !mediaFile) return;

    const user = auth.currentUser;
    const userRef = ref(database, `users/${user.uid}`);
    const snapshot = await get(userRef);

    if (!snapshot.exists()) return;

    const userData = snapshot.val();
    const displayName = userData.displayName || 'Anonymous';
    const postId = push(ref(database, 'posts')).key;

    let mediaUrl = '';
    if (mediaFile) {
      const storage = getStorage();
      const mediaStorageRef = storageRef(storage, `posts/${postId}/${mediaFile.name}`);
      await uploadBytes(mediaStorageRef, mediaFile);
      mediaUrl = await getDownloadURL(mediaStorageRef);
    }

    const post = {
      id: postId,
      userId: user.uid,
      displayName,
      text: newPost,
      mediaUrl,
      timestamp: new Date().getTime(),
    };

    const updates = {};
    updates[`/posts/${user.uid}/${postId}`] = post;
    updates[`/feed/${postId}`] = post;

    await update(ref(database), updates);
    setPosts([...posts, post]);
    setNewPost('');
    setMediaFile(null);
  };

  if (loading) {
    return <p>Loading...</p>;
  }

  return (
    <div className="profile-container">
      <div className="profile-header">
        <div className="profile-picture-container">
          <img src={profileData.profilePicture} alt="Profile" className="profile-picture" />
          {editing && uid === undefined && (
            <>
              <input type="file" id="profilePictureUpload" onChange={handleProfilePictureChange} />
              <label htmlFor="profilePictureUpload">Upload Picture</label>
            </>
          )}
        </div>
        <div className="profile-details">
          {editing && uid === undefined ? (
            <>
              <input
                type="text"
                value={profileData.displayName}
                onChange={(e) => setProfileData({ ...profileData, displayName: e.target.value })}
              />
              <textarea
                value={profileData.bio}
                onChange={(e) => setProfileData({ ...profileData, bio: e.target.value })}
              />
              <button onClick={handleSave}>Save</button>
            </>
          ) : (
            <>
              <h3>{profileData.displayName}</h3>
              <p>{profileData.bio}</p>
              {uid === undefined && <button onClick={() => setEditing(true)}>Edit Profile</button>}
            </>
          )}
          {isAdmin && <button onClick={() => navigate('/agbank-dashboard')}>Admin Dashboard</button>}
        </div>
      </div>

      <div className="status-update">
        <textarea
          value={newPost}
          onChange={(e) => setNewPost(e.target.value)}
          placeholder="What's on your mind?"
        />
        <input type="file" onChange={(e) => setMediaFile(e.target.files[0])} />
        <button onClick={handlePost}>Post</button>
      </div>

      <div className="posts-section">
        <h3>Posts</h3>
        {posts.map((post) => (
          <div key={post.id} className="post">
            <p>{post.text}</p>
            {post.mediaUrl && <img src={post.mediaUrl} alt="Post media" />}
            <div className="post-actions">
              <button>
                <FaHeart /> {likes[post.id]?.count || 0}
              </button>
              <button>
                <FaComment />
              </button>
              <button>
                <FaShare />
              </button>
            </div>
          </div>
        ))}
      </div>

      <div className="ai-ar-section">
        <h3>AI/AR Assistant</h3>
        <AROrb />
      </div>
    </div>
  );
};

export default Profile;
