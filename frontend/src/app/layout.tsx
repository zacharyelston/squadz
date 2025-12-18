import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Squadz - GPS Squad Tracking',
  description: 'Share your location with your squad in real-time',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <link
          rel="stylesheet"
          href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"
        />
      </head>
      <body className="bg-gray-900 text-white min-h-screen" suppressHydrationWarning>{children}</body>
    </html>
  );
}
