/**
 * Minimal stand-ins for React Native host components, so the sheet can render in Node with
 * react-test-renderer. They keep their props, which the tests read.
 */
import { createElement, type ReactNode } from 'react';

type Props = Record<string, unknown> & { children?: ReactNode };

function host(name: string) {
  const Component = (props: Props) => createElement(name, props, props.children);
  Component.displayName = name;
  return Component;
}

export const View = host('View');
export const Text = host('Text');
export const TextInput = host('TextInput');
export const Pressable = host('Pressable');
export const ScrollView = host('ScrollView');
export const Image = host('Image');
export const ActivityIndicator = host('ActivityIndicator');
export const KeyboardAvoidingView = host('KeyboardAvoidingView');
export const Modal = (props: Props & { visible?: boolean }) =>
  props.visible ? createElement('Modal', props, props.children) : null;

export const Platform = { OS: 'ios', Version: '18.2', select: <T,>(options: { ios?: T; default?: T }) => options.ios };

export const StyleSheet = { create: <T,>(styles: T): T => styles };
