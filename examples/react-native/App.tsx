/**
 * Usage snippet for @krffl/tododdle-support-react-native. Drop it into any React Native or Expo app.
 * The SDK never captures the screen: this example lets the person pick an image with
 * expo-image-picker, which is the app's choice, not an SDK dependency.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
import { createTododdleSupport, ReportSheet } from '@krffl/tododdle-support-react-native';
import * as ImagePicker from 'expo-image-picker';
import { useEffect, useState } from 'react';
import { Button, SafeAreaView } from 'react-native';

const support = createTododdleSupport({
  key: 'tdsk_test_REPLACE_ME',
  appId: 'com.example.mosslight',
  appVersion: '2.4.0',
  build: '118',
  storage: AsyncStorage,
  offlineQueue: true,
});

export default function App() {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    // Send reports that were queued while offline.
    void support.flushQueue();
  }, []);

  return (
    <SafeAreaView>
      <Button title="Report a problem" onPress={() => setOpen(true)} />
      <ReportSheet
        client={support}
        visible={open}
        onClose={() => setOpen(false)}
        context={{ screen: 'Favourites' }}
        reporter={{ customerReference: 'user-42' }}
        onRequestScreenshot={async () => {
          const picked = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images'] });
          const asset = picked.canceled ? undefined : picked.assets[0];
          return asset ? { uri: asset.uri, fileName: asset.fileName ?? undefined } : null;
        }}
        onSubmitted={(result) => console.log('Report', result)}
      />
    </SafeAreaView>
  );
}
