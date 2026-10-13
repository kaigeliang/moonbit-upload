///|
let constants : FixedArray[UInt32] = [
  0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U,
  0xab1c5ed5U, 0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU,
  0x9bdc06a7U, 0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU,
  0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
  0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
  0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U, 0xa2bfe8a1U, 0xa81a664bU,
  0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U,
  0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
  0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U,
  0xc67178f2U,
]

///|
pub struct Hasher {
  priv state : FixedArray[UInt32]
  priv block : FixedArray[Byte]
  priv words : FixedArray[UInt32]
  priv mut used : Int32
  priv mut length : Int64
}

///|
pub fn Hasher::new() -> Hasher {
  {
    state: [
      0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU, 0x510e527fU, 0x9b05688cU,
      0x1f83d9abU, 0x5be0cd19U,
    ],
    block: FixedArray::make(64, b'\x00'),
    words: FixedArray::make(64, 0U),
    used: 0,
    length: 0L,
  }
}

///|
fn rotr(x : UInt32, n : Int32) -> UInt32 {
  (x >> n) | (x << (32 - n))
}

///|
fn Hasher::compress(self : Hasher) -> Unit {
  let w = self.words
  for i = 0; i < 16; i = i + 1 {
    let j = i * 4
    w[i] = (self.block[j].to_int().reinterpret_as_uint() << 24) |
      (self.block[j + 1].to_int().reinterpret_as_uint() << 16) |
      (self.block[j + 2].to_int().reinterpret_as_uint() << 8) |
      self.block[j + 3].to_int().reinterpret_as_uint()
  }
  for i = 16; i < 64; i = i + 1 {
    let x = w[i - 15]
    let y = w[i - 2]
    w[i] = w[i - 16] +
      (rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3)) +
      w[i - 7] +
      (rotr(y, 17) ^ rotr(y, 19) ^ (y >> 10))
  }
  let mut a = self.state[0]
  let mut b = self.state[1]
  let mut c = self.state[2]
  let mut d = self.state[3]
  let mut e = self.state[4]
  let mut f = self.state[5]
  let mut g = self.state[6]
  let mut h = self.state[7]
  for i = 0; i < 64; i = i + 1 {
    let t1 = h +
      (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) +
      ((e & f) ^ ((e ^ 0xffffffffU) & g)) +
      constants[i] +
      w[i]
    let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) +
      ((a & b) ^ (a & c) ^ (b & c))
    h = g
    g = f
    f = e
    e = d + t1
    d = c
    c = b
    b = a
    a = t1 + t2
  }
  let result : FixedArray[UInt32] = [a, b, c, d, e, f, g, h]
  for i = 0; i < 8; i = i + 1 {
    self.state[i] += result[i]
  }
}

///|
pub fn Hasher::update(self : Hasher, data : Bytes) -> Unit {
  self.length += data.length().to_int64()
  for byte in data {
    self.block[self.used] = byte
    self.used += 1
    if self.used == 64 {
      self.compress()
      self.used = 0
    }
  }
}

///|
/// Finalizes the hasher; do not update or finalize it again.
pub fn Hasher::finish(self : Hasher) -> String {
  let bits = self.length * 8L
  self.block[self.used] = b'\x80'
  self.used += 1
  if self.used > 56 {
    for i = self.used; i < 64; i = i + 1 {
      self.block[i] = b'\x00'
    }
    self.compress()
    self.used = 0
  }
  for i = self.used; i < 56; i = i + 1 {
    self.block[i] = b'\x00'
  }
  for i = 0; i < 8; i = i + 1 {
    self.block[63 - i] = (bits >> (i * 8)).to_int().to_byte()
  }
  self.compress()
  let hex = "0123456789abcdef"
  let out = StringBuilder()
  for word in self.state {
    for i = 7; i >= 0; i = i - 1 {
      out.write_char(
        hex[((word >> (i * 4)) & 15U).reinterpret_as_int()].to_char().unwrap(),
      )
    }
  }
  out.to_string()
}
