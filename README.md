# Tx 800 Mini

## ফোল্ডার স্ট্রাকচার (GitHub repo)

```
tx800_mini/
├── .github/workflows/build_apk.yml
├── lib/main.dart
├── assets/audio/            <- (ঐচ্ছিক) নিজের মিউজিক এখানে
│   ├── bgm.mp3              <- ব্যাকগ্রাউন্ড মিউজিক (লুপ হবে)
│   └── arpeggio.mp3         <- মাইক ট্যাপ সাউন্ড
└── pubspec.yaml
```

## অডিও অ্যাসেট

- কোনো ফাইল না দিলেও চলবে: অ্যাপ নিজেই ambient লুপ ও arpeggio সাউন্ড তৈরি (synthesize) করে নেয়।
- নিজের সাউন্ড চাইলে ফাইলের নাম ঠিক `bgm.mp3` ও `arpeggio.mp3` রাখুন এবং `assets/audio/` এ রাখুন।
- `bgm.mp3` seamless লুপ হলে ভালো শোনাবে।

## বিল্ড

1. সব ফাইল repo-তে push করুন (main/master ব্রাঞ্চ)।
2. GitHub › Actions › Build APK চালান।
3. শেষে Artifacts থেকে `tx800-mini-apk` ডাউনলোড করুন।

`android/` ফোল্ডার না থাকলে workflow নিজেই তৈরি করে permission ও minSdk বসিয়ে নেয়।

## বাংলা ভয়েস

ফোনে Settings › Text-to-speech এ Google TTS এর বাংলা (bn-BD) ভয়েস ইনস্টল থাকতে হবে।
