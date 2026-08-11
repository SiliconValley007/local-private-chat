import 'dart:async';
import 'dart:io';

import 'api_client.dart';

/// Plain-language text for anything we might catch, safe to show in the UI.
///
/// Raw exception text (socket errors, JSON dumps, stack traces) is never useful
/// to someone using the app, so everything funnels through here first.
String friendlyMessage(Object error) {
  if (error is ApiException) return error.message;
  if (error is TimeoutException) return _timeout;
  if (error is SocketException || error is HttpException) return _unreachable;
  if (error is HandshakeException) return _unreachable;
  if (error is FormatException) return _badResponse;
  if (error is FileSystemException) {
    return 'This phone would not let the app open that file. Try another one.';
  }
  return 'Something went wrong. Please try again.';
}

const _unreachable =
    "Can't reach the server. Check that Tailscale is connected on this phone "
    'and that the server phone is on and running Local Chat.';
const _timeout =
    'The server took too long to reply. Check your Tailscale connection and try again.';
const _badResponse =
    "The server sent a reply the app didn't understand. Make sure both phones "
    'are on the same app version.';

/// Network-level failures mapped to advice, used by [ApiClient].
String networkMessageFor(Object error) {
  if (error is TimeoutException) return _timeout;
  if (error is FormatException) return _badResponse;
  return _unreachable;
}

/// Fallback text per HTTP status, used when the server sends no readable detail.
String statusMessageFor(int statusCode) {
  switch (statusCode) {
    case 400:
      return "That didn't look right. Please check what you entered and try again.";
    case 401:
      return 'Your session has expired. Please sign in again.';
    case 403:
      return "You don't have access to that.";
    case 404:
      return "We couldn't find what you were looking for.";
    case 409:
      return 'That conflicts with something that already exists.';
    case 413:
      return 'That file is too large to send.';
    case 422:
      return "Some of the details you entered aren't valid.";
    case 429:
      return 'Too many attempts. Please wait a moment and try again.';
    case 502:
    case 503:
    case 504:
      return 'The server is not responding right now. Please try again in a moment.';
    default:
      if (statusCode >= 500) {
        return 'The server ran into a problem. Please try again.';
      }
      return 'That request could not be completed. Please try again.';
  }
}
