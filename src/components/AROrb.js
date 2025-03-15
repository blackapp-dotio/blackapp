import React, { useEffect, useRef, useState } from 'react';
import { View, Text, TouchableOpacity, Modal, StyleSheet } from 'react-native';
import { GLView } from 'expo-gl';
import { Renderer, TextureLoader } from 'expo-three';
import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls';

const AROrb = () => {
    const [isModalOpen, setIsModalOpen] = useState(false);
    const [activeEffects, setActiveEffects] = useState({
        hud: false,
        time: false,
        stocks: false,
    });

    let camera, scene, renderer, orb, texture, controls;

    useEffect(() => {
        if (isModalOpen) {
            // Reset active effects when opening
            setActiveEffects({ hud: false, time: false, stocks: false });
        }
    }, [isModalOpen]);

    const createAROrb = async (gl) => {
        scene = new THREE.Scene();
        camera = new THREE.PerspectiveCamera(50, gl.drawingBufferWidth / gl.drawingBufferHeight, 0.1, 1000);
        camera.position.set(0, 0, 15);

        renderer = new Renderer({ gl, antialias: true });
        renderer.setSize(gl.drawingBufferWidth, gl.drawingBufferHeight);
        renderer.setClearColor(0x000000, 0);

        controls = new OrbitControls(camera, gl.canvas);
        controls.enableDamping = true;

        const geometry = new THREE.SphereGeometry(5, 64, 64);
        texture = new TextureLoader().load('https://via.placeholder.com/512'); // Placeholder texture

        const material = new THREE.MeshPhysicalMaterial({
            map: texture,
            color: 0x0077ff,
            emissive: 0x001122,
            clearcoat: 1.0,
            roughness: 0.5,
            opacity: 0.8,
            transparent: true,
        });

        orb = new THREE.Mesh(geometry, material);
        scene.add(orb);

        scene.add(new THREE.AmbientLight(0xffffff, 0.5));
        const directionalLight = new THREE.DirectionalLight(0xffffff, 1);
        directionalLight.position.set(10, 10, 10);
        scene.add(directionalLight);

        const animate = () => {
            requestAnimationFrame(animate);
            orb.rotation.y += 0.01;
            controls.update();
            renderer.render(scene, camera);
            gl.endFrameEXP();
        };

        animate();
    };

    const toggleEffect = (effectName) => {
        setActiveEffects((prevEffects) => ({
            ...prevEffects,
            [effectName]: !prevEffects[effectName],
        }));
    };

    return (
        <View style={styles.container}>
            <TouchableOpacity style={styles.openButton} onPress={() => setIsModalOpen(true)}>
                <Text style={styles.buttonText}>Open AR Orb</Text>
            </TouchableOpacity>

            {isModalOpen && (
                <Modal animationType="fade" transparent={true} visible={isModalOpen}>
                    <View style={styles.modalContainer}>
                        <GLView
                            style={styles.glView}
                            onContextCreate={createAROrb}
                        />
                        <View style={styles.buttonContainer}>
                            {['hud', 'time', 'stocks'].map((effect) => (
                                <TouchableOpacity
                                    key={effect}
                                    style={styles.effectButton}
                                    onPress={() => toggleEffect(effect)}
                                >
                                    <Text style={styles.buttonText}>
                                        Toggle {effect.charAt(0).toUpperCase() + effect.slice(1)}
                                    </Text>
                                </TouchableOpacity>
                            ))}
                        </View>
                        <TouchableOpacity style={styles.closeButton} onPress={() => setIsModalOpen(false)}>
                            <Text style={styles.buttonText}>Close</Text>
                        </TouchableOpacity>
                    </View>
                </Modal>
            )}
        </View>
    );
};

const styles = StyleSheet.create({
    container: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
    },
    openButton: {
        padding: 12,
        backgroundColor: '#007bff',
        borderRadius: 10,
    },
    modalContainer: {
        flex: 1,
        backgroundColor: 'rgba(0,0,0,0.9)',
        alignItems: 'center',
        justifyContent: 'center',
    },
    glView: {
        width: '100%',
        height: '70%',
    },
    buttonContainer: {
        flexDirection: 'row',
        marginTop: 10,
    },
    effectButton: {
        padding: 10,
        marginHorizontal: 5,
        backgroundColor: 'rgba(255, 255, 255, 0.2)',
        borderRadius: 8,
    },
    closeButton: {
        marginTop: 20,
        padding: 12,
        backgroundColor: 'rgba(255, 255, 255, 0.3)',
        borderRadius: 10,
    },
    buttonText: {
        color: 'white',
        textAlign: 'center',
    },
});

export default AROrb;
