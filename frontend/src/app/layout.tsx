import type { Metadata } from 'next';
import './globals.css';
import 'leaflet/dist/leaflet.css';

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
      <body className="bg-gray-900 text-white min-h-screen" suppressHydrationWarning>{children}</body>
    </html>
  );
}
