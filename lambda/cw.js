// Structured logs + CloudWatch custom metrics via Embedded Metric Format
const NS = 'ICPL';
exports.log = (level, message, fields = {}) =>
  console.log(JSON.stringify({ level, message, ...fields }));

exports.metric = (name, value = 1, unit = 'Count', dims = {}) => {
  console.log(JSON.stringify({
    _aws: {
      Timestamp: Date.now(),
      CloudWatchMetrics: [{ Namespace: NS, Dimensions: [Object.keys(dims)], Metrics: [{ Name: name, Unit: unit }] }],
    },
    ...dims,
    [name]: value,
  }));
};
