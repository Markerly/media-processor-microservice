#!/bin/bash

echo "Testing Rate Limiting..."
echo "Making 105 requests to test the 100 request limit..."
echo ""

for i in {1..105}; do
  STATUS=$(curl -s -w "%{http_code}" -o /dev/null http://localhost:8082/)
  
  if [ "$STATUS" == "429" ]; then
    echo "Request $i: RATE LIMITED (429) ✓"
    break
  elif [ "$i" -gt 100 ]; then
    echo "Request $i: Status $STATUS (Expected 429!)"
  elif [ $(($i % 25)) -eq 0 ]; then
    echo "Request $i: Status $STATUS"
  fi
done

echo ""
echo "Testing rate limit response format:"
curl -s http://localhost:8082/ | python -m json.tool 2>/dev/null || echo "Rate limited!"
