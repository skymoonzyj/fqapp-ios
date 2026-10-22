import 'package:flutter/material.dart';

// XCTest host only: load the real implicit engine and registered adapters
// without starting production networking or opening the user's local stores.
void main() => runApp(const MaterialApp(home: SizedBox.shrink()));
