/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  allowedDevOrigins: ['*'],
  async rewrites() {
    return [
      {
        source: '/api/:path*',
        destination: 'http://localhost:8090/api/:path*',
      },
    ];
  },
};

module.exports = nextConfig;
