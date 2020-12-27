const { merge } = require('webpack-merge');
const common = require('./webpack.common.js');
const CssMinimizerPlugin = require('css-minimizer-webpack-plugin');
const { CleanWebpackPlugin } = require('clean-webpack-plugin');

module.exports = merge(common, {
  mode: 'production',
  optimization: {
    minimizer: [
      new CssMinimizerPlugin(),
    ],
  },
  plugins: [
    new CleanWebpackPlugin({
      cleanOnceBeforeBuildPatterns: [
        'assets/*',
        'main.js',
        'main.js.map',
      ],
    }),
  ],
});
