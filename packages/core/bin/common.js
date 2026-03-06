const path = require('path');
const { mkdir, writeFile } = require('fs/promises');

// Polyfill SlowBuffer for legacy dependencies (e.g. avsc) in Node 25+
if (typeof global.SlowBuffer === 'undefined') {
	global.SlowBuffer = global.Buffer;
}
const buffer = require('buffer');
if (!buffer.SlowBuffer) {
	buffer.SlowBuffer = buffer.Buffer;
}

const packageDir = process.cwd();
const distDir = path.join(packageDir, 'dist');

const writeJSON = async (file, data) => {
	const filePath = path.resolve(distDir, file);
	await mkdir(path.dirname(filePath), { recursive: true });
	const payload = Array.isArray(data)
		? `[\n${data.map((entry) => JSON.stringify(entry)).join(',\n')}\n]`
		: JSON.stringify(data, null, 2);
	await writeFile(filePath, payload, { encoding: 'utf-8' });
};

module.exports = {
	packageDir,
	writeJSON,
};
